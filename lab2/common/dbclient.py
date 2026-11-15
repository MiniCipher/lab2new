"""
Мінімальні клієнти PostgreSQL та Redis лише на стандартній бібліотеці Python.

Навіщо власні клієнти, а не psycopg / redis-py:
  * однакова «вага» клієнта для обох СКБД: та сама мова, той самий спосіб
    роботи із сокетом (TCP_NODELAY, буферизоване читання), без C-розширень
    у одного й чистого Python у іншого — різниця в часі визначається
    сервером і протоколом, а не якістю драйвера;
  * нуль залежностей: бенчмарк запускається на будь-якій машині з Python 3.9+.

PostgreSQL: протокол v3, simple query; автентифікація trust / cleartext / md5 /
SCRAM-SHA-256. Параметри підставляються як екрановані літерали; для «гарячих»
запитів використовується серверний PREPARE/EXECUTE (план кешується на сервері,
так само як у psycopg з prepare=True).
Redis: протокол RESP2, конвеєри (pipeline), EVALSHA з автозавантаженням скрипта.
"""
from __future__ import annotations

import base64
import datetime as _dt
import decimal
import hashlib
import hmac
import os
import re
import socket
import struct


# =====================================================================
# PostgreSQL
# =====================================================================
class PgError(Exception):
    def __init__(self, fields: dict):
        self.fields = fields
        self.sqlstate = fields.get("C")
        super().__init__(f"{fields.get('S', 'ERROR')} {self.sqlstate}: {fields.get('M')}")


def _int(v): return int(v)
def _bool(v): return v == "t"


_CONVERTERS = {16: _bool, 20: _int, 21: _int, 23: _int, 26: _int,
               700: float, 701: float, 1700: decimal.Decimal}

_PARAM_RE = re.compile(r"%s|%%")


def pg_literal(v) -> str:
    if v is None:
        return "NULL"
    if isinstance(v, bool):
        return "TRUE" if v else "FALSE"
    if isinstance(v, (int, float, decimal.Decimal)):
        return str(v)
    if isinstance(v, (_dt.datetime, _dt.date)):
        v = v.isoformat()
    s = str(v)
    if "\x00" in s:
        raise ValueError("NUL byte in string literal")
    return "'" + s.replace("'", "''") + "'"   # standard_conforming_strings = on


def pg_format(sql: str, params=None) -> str:
    if not params:
        return sql.replace("%%", "%") if params is not None else sql
    it = iter(params)
    return _PARAM_RE.sub(lambda m: "%" if m.group() == "%%" else pg_literal(next(it)), sql)


class PgConnection:
    def __init__(self, host="127.0.0.1", port=5432, user="postgres", password="",
                 dbname="restaurant", connect_timeout=10):
        self.sock = socket.create_connection((host, port), timeout=connect_timeout)
        self.sock.settimeout(None)
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.rf = self.sock.makefile("rb", buffering=65536)
        self.user, self.password = user, password
        self._prepared: set[str] = set()
        self._startup(dbname)

    # --- low level -----------------------------------------------------
    def _send(self, typ: bytes, payload: bytes):
        self.sock.sendall(typ + struct.pack("!I", len(payload) + 4) + payload)

    def _recv(self):
        hdr = self.rf.read(5)
        if len(hdr) < 5:
            raise ConnectionError("PostgreSQL closed connection")
        typ, ln = hdr[:1], struct.unpack("!I", hdr[1:])[0]
        return typ, self.rf.read(ln - 4)

    @staticmethod
    def _err_fields(body: bytes) -> dict:
        out = {}
        for part in body.split(b"\x00"):
            if part:
                out[chr(part[0])] = part[1:].decode("utf-8", "replace")
        return out

    def _startup(self, dbname):
        params = b"".join(k.encode() + b"\x00" + v.encode() + b"\x00" for k, v in
                          (("user", self.user), ("database", dbname), ("client_encoding", "UTF8"),
                           ("application_name", "lab2-bench"))) + b"\x00"
        body = struct.pack("!I", 196608) + params
        self.sock.sendall(struct.pack("!I", len(body) + 4) + body)
        scram = None
        while True:
            typ, body = self._recv()
            if typ == b"R":
                code = struct.unpack("!I", body[:4])[0]
                if code == 0:
                    continue
                if code == 3:                                   # cleartext
                    self._send(b"p", self.password.encode() + b"\x00")
                elif code == 5:                                 # md5
                    salt = body[4:8]
                    inner = hashlib.md5((self.password + self.user).encode()).hexdigest()
                    outer = hashlib.md5(inner.encode() + salt).hexdigest()
                    self._send(b"p", b"md5" + outer.encode() + b"\x00")
                elif code == 10:                                # SASL: SCRAM-SHA-256
                    scram = _Scram(self.password)
                    first = scram.client_first().encode()
                    self._send(b"p", b"SCRAM-SHA-256\x00" + struct.pack("!I", len(first)) + first)
                elif code == 11:
                    self._send(b"p", scram.client_final(body[4:].decode()).encode())
                elif code == 12:
                    scram.verify(body[4:].decode())
                else:
                    raise PgError({"M": f"unsupported auth method {code}"})
            elif typ == b"E":
                raise PgError(self._err_fields(body))
            elif typ == b"Z":
                return
            # S (ParameterStatus), K (BackendKeyData), N (Notice) — ігноруємо

    # --- public API ----------------------------------------------------
    def query(self, sql: str, params=None):
        """Виконати SQL (можна кілька операторів). Повертає рядки останнього SELECT."""
        self._send(b"Q", pg_format(sql, params).encode() + b"\x00")
        rows, conv, cols, err = [], None, None, None
        last_rows = []
        while True:
            typ, body = self._recv()
            if typ == b"D":
                n = struct.unpack("!H", body[:2])[0]
                pos, row = 2, []
                for i in range(n):
                    ln = struct.unpack("!i", body[pos:pos + 4])[0]
                    pos += 4
                    if ln < 0:
                        row.append(None)
                    else:
                        v = body[pos:pos + ln].decode()
                        pos += ln
                        f = conv[i]
                        row.append(f(v) if f else v)
                rows.append(tuple(row))
            elif typ == b"T":
                n = struct.unpack("!H", body[:2])[0]
                pos, conv, cols = 2, [], []
                for _ in range(n):
                    end = body.index(b"\x00", pos)
                    cols.append(body[pos:end].decode())
                    pos = end + 1
                    oid = struct.unpack("!I", body[pos + 6:pos + 10])[0]
                    conv.append(_CONVERTERS.get(oid))
                    pos += 18
                rows = []
            elif typ == b"C":
                last_rows, self.columns = rows, cols
                rows = []
            elif typ == b"E":
                err = PgError(self._err_fields(body))
            elif typ == b"Z":
                if err:
                    raise err
                return last_rows
            # N, S, I — ігноруємо

    def query_one(self, sql, params=None):
        r = self.query(sql, params)
        return r[0] if r else None

    def scalar(self, sql, params=None):
        r = self.query_one(sql, params)
        return r[0] if r else None

    def prepare(self, name: str, sql: str):
        """sql з параметрами $1, $2 ... (серверний prepared statement)."""
        if name not in self._prepared:
            self.query(f"PREPARE {name} AS {sql}")
            self._prepared.add(name)

    def deallocate_all(self):
        self.query("DEALLOCATE ALL")
        self._prepared.clear()

    def execute_prepared(self, name: str, args=()):
        lits = ", ".join(pg_literal(a) for a in args)
        return self.query(f"EXECUTE {name}({lits})" if args else f"EXECUTE {name}")

    def close(self):
        try:
            self._send(b"X", b"")
        finally:
            self.sock.close()


class _Scram:
    def __init__(self, password: str):
        self.password = password.encode()
        self.cnonce = base64.b64encode(os.urandom(18)).decode()

    def client_first(self):
        self.bare = f"n=,r={self.cnonce}"
        return "n,," + self.bare

    def client_final(self, server_first: str):
        attrs = dict(kv.split("=", 1) for kv in server_first.split(","))
        nonce, salt, it = attrs["r"], base64.b64decode(attrs["s"]), int(attrs["i"])
        salted = hashlib.pbkdf2_hmac("sha256", self.password, salt, it)
        client_key = hmac.new(salted, b"Client Key", hashlib.sha256).digest()
        stored = hashlib.sha256(client_key).digest()
        without_proof = f"c=biws,r={nonce}"
        auth_msg = f"{self.bare},{server_first},{without_proof}".encode()
        sig = hmac.new(stored, auth_msg, hashlib.sha256).digest()
        proof = bytes(a ^ b for a, b in zip(client_key, sig))
        server_key = hmac.new(salted, b"Server Key", hashlib.sha256).digest()
        self.expected = base64.b64encode(hmac.new(server_key, auth_msg, hashlib.sha256).digest()).decode()
        return f"{without_proof},p={base64.b64encode(proof).decode()}"

    def verify(self, server_final: str):
        if server_final.split("v=", 1)[-1] != self.expected:
            raise PgError({"M": "SCRAM server signature mismatch"})


# =====================================================================
# Redis
# =====================================================================
class RedisError(Exception):
    pass


def _enc(a) -> bytes:
    if isinstance(a, bytes):
        return a
    if isinstance(a, float):
        return repr(a).encode()
    return str(a).encode()


class RedisConnection:
    def __init__(self, host="127.0.0.1", port=6379, password=None, db=0):
        self.sock = socket.create_connection((host, port), timeout=10)
        self.sock.settimeout(None)
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.rf = self.sock.makefile("rb", buffering=65536)
        if password:
            self.call("AUTH", password)
        if db:
            self.call("SELECT", db)

    @staticmethod
    def _pack(args) -> bytes:
        out = [b"*%d\r\n" % len(args)]
        for a in args:
            b = _enc(a)
            out.append(b"$%d\r\n%s\r\n" % (len(b), b))
        return b"".join(out)

    def _read(self):
        line = self.rf.readline()
        if not line:
            raise ConnectionError("Redis closed connection")
        t, rest = line[:1], line[1:-2]
        if t == b"+":
            return rest.decode()
        if t == b"-":
            return RedisError(rest.decode())
        if t == b":":
            return int(rest)
        if t == b"$":
            n = int(rest)
            if n < 0:
                return None
            data = self.rf.read(n + 2)[:-2]
            return data.decode()
        if t == b"*":
            n = int(rest)
            if n < 0:
                return None
            return [self._read() for _ in range(n)]
        raise RedisError(f"protocol error: {line!r}")

    def call(self, *args):
        self.sock.sendall(self._pack(args))
        r = self._read()
        if isinstance(r, RedisError):
            raise r
        return r

    def pipeline(self, commands, raise_on_error=True):
        """Відправити кілька команд одним пакетом (1 RTT) і прочитати всі відповіді."""
        self.sock.sendall(b"".join(self._pack(c) for c in commands))
        res = [self._read() for _ in commands]
        if raise_on_error:
            for r in res:
                if isinstance(r, RedisError):
                    raise r
        return res

    def script(self, source: str) -> "RedisScript":
        return RedisScript(self, source)

    def close(self):
        self.sock.close()


class RedisScript:
    """Lua-скрипт, що виконується атомарно на сервері (EVALSHA, при NOSCRIPT — SCRIPT LOAD)."""

    def __init__(self, conn: RedisConnection, source: str):
        self.conn, self.source = conn, source
        self.sha = hashlib.sha1(source.encode()).hexdigest()

    def __call__(self, keys=(), args=()):
        try:
            return self.conn.call("EVALSHA", self.sha, len(keys), *keys, *args)
        except RedisError as e:
            if not str(e).startswith("NOSCRIPT"):
                raise
            self.conn.call("SCRIPT", "LOAD", self.source)
            return self.conn.call("EVALSHA", self.sha, len(keys), *keys, *args)


# =====================================================================
# Налаштування з'єднань через змінні середовища
# =====================================================================
def pg_connect() -> PgConnection:
    return PgConnection(host=os.getenv("PGHOST", "127.0.0.1"), port=int(os.getenv("PGPORT", "5432")),
                        user=os.getenv("PGUSER", "postgres"), password=os.getenv("PGPASSWORD", ""),
                        dbname=os.getenv("PGDATABASE", "restaurant"))


def redis_connect() -> RedisConnection:
    return RedisConnection(host=os.getenv("REDIS_HOST", "127.0.0.1"), port=int(os.getenv("REDIS_PORT", "6379")),
                           password=os.getenv("REDIS_PASSWORD") or None)
