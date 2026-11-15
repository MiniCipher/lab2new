// =====================================================================
// ЛР2, частина 6 — MongoDB (документна БД): відгуки гостей ресторану
//   mongosh "mongodb://localhost:27017" mongo/01_setup.js
//
// Чому документна модель для відгуків:
//   * структура різна: оцінка може бути лише загальною або з деталізацією
//     по стравах; фото — 0..N; відповідь адміністратора — є або немає;
//     відгуки з різних каналів (QR, Google, офіціант) мають різні поля;
//   * відгук читається і змінюється як ціле (агрегат), JOIN-и не потрібні;
//   * назва страви в відгуку — історичний знімок (як у чеку), а dishId —
//     посилання на актуальний каталог (колекція dishes, копія меню з PostgreSQL).
// =====================================================================
db = db.getSiblingDB("restaurant_docs");
db.reviews.drop();
db.dishes.drop();

// --- Колекція-довідник: копія меню з PostgreSQL (dishId = dishes.dish_id) ----
db.createCollection("dishes", {
  validator: { $jsonSchema: {
    bsonType: "object",
    required: ["_id", "name", "category", "priceMinor", "active"],
    properties: {
      _id:        { bsonType: "int", description: "dish_id з PostgreSQL" },
      name:       { bsonType: "string" },
      category:   { bsonType: "string" },
      priceMinor: { bsonType: "int", minimum: 0 },
      active:     { bsonType: "bool" }
    }
  } }
});

// --- Основна колекція: відгуки з валідацією структури -----------------------
db.createCollection("reviews", {
  validator: { $jsonSchema: {
    bsonType: "object",
    required: ["orderId", "visitAt", "channel", "ratings", "status", "schemaVersion"],
    properties: {
      orderId:  { bsonType: "long", description: "orders.order_id у PostgreSQL" },
      tableNo:  { bsonType: "int" },
      visitAt:  { bsonType: "date" },
      channel:  { enum: ["qr", "google", "staff"] },
      customer: { bsonType: "object", required: ["name"],
                  properties: { id: { bsonType: "int" }, name: { bsonType: "string" } } },
      ratings:  { bsonType: "object", required: ["overall"],
                  properties: {
                    overall:  { bsonType: "int", minimum: 1, maximum: 5 },
                    food:     { bsonType: "int", minimum: 1, maximum: 5 },
                    service:  { bsonType: "int", minimum: 1, maximum: 5 },
                    ambience: { bsonType: "int", minimum: 1, maximum: 5 } } },
      dishes:   { bsonType: "array", maxItems: 30,               // обмежений масив
                  items: { bsonType: "object", required: ["dishId", "name", "rating"],
                           properties: { dishId: { bsonType: "int" }, name: { bsonType: "string" },
                                         rating: { bsonType: "int", minimum: 1, maximum: 5 },
                                         tags:   { bsonType: "array", items: { bsonType: "string" } } } } },
      text:     { bsonType: "string", maxLength: 4000 },
      photos:   { bsonType: "array", maxItems: 10 },
      reply:    { bsonType: "object", required: ["by", "at", "text"] },
      status:   { enum: ["new", "answered", "hidden"] },
      helpful:  { bsonType: "int", minimum: 0 },
      schemaVersion: { bsonType: "int" }
    }
  } },
  validationAction: "error"
});

// --- Тестові дані ---------------------------------------------------------
const CATS = ["Закуски", "Основні страви", "Десерти", "Напої"];
const dishes = [
  { _id: 1, name: "Брускета з томатами", category: "Закуски",        priceMinor: 12000, active: true },
  { _id: 2, name: "Курча по-київськи",   category: "Основні страви", priceMinor: 28000, active: true },
  { _id: 3, name: "Піца Маргарита",      category: "Основні страви", priceMinor: 22000, active: true },
  { _id: 4, name: "Тірамісу",            category: "Десерти",        priceMinor: 15000, active: true },
  { _id: 5, name: "Еспресо",             category: "Напої",          priceMinor: 6000,  active: true }
];
for (let i = 1; i <= 45; i++) {
  dishes.push({ _id: 5 + i, name: "Страва " + i, category: CATS[i % 4],
                priceMinor: NumberInt(6000 + (i * 997) % 50000), active: i % 13 !== 0 });
}
dishes.forEach(d => { d._id = NumberInt(d._id); d.priceMinor = NumberInt(d.priceMinor); });
db.dishes.insertMany(dishes);

// Детермінований ГПВЧ, щоб дані були однаковими при кожному запуску
let seed = 42;
const rnd = () => (seed = (seed * 16807) % 2147483647) / 2147483647;   // Park–Miller, без втрати точності
const pick = arr => arr[Math.floor(rnd() * arr.length)];
const TAGS = ["смачно", "гаряче", "холодне", "велика порція", "мала порція", "пересолено", "красива подача", "довго чекали"];
const TEXTS = ["Все сподобалось, повернемось ще!", "Смачно, але довго чекали замовлення.",
               "Чудова тераса і уважний офіціант.", "Піца трохи пересолена.", "Найкращий тірамісу в місті",
               "Гучна музика, але кухня на висоті.", "Порції великі, ціни адекватні."];
const docs = [];
const base = new Date("2026-01-01T12:00:00Z").getTime();
for (let i = 0; i < 5000; i++) {
  const overall = 1 + Math.floor(Math.pow(rnd(), 0.5) * 5);          // зсув до високих оцінок
  const doc = {
    orderId: NumberLong(String(1000 + i)), tableNo: NumberInt(1 + Math.floor(rnd() * 100)),
    visitAt: new Date(base + Math.floor(rnd() * 300) * 86400000 + Math.floor(rnd() * 43200000)),
    channel: pick(["qr", "qr", "qr", "google", "staff"]),
    ratings: { overall: NumberInt(Math.min(overall, 5)) },
    status: "new", helpful: NumberInt(0), schemaVersion: NumberInt(1)
  };
  if (rnd() < 0.6) {           // детальні оцінки є не завжди — гнучка схема
    doc.ratings.food = NumberInt(1 + Math.floor(rnd() * 5));
    doc.ratings.service = NumberInt(1 + Math.floor(rnd() * 5));
    doc.ratings.ambience = NumberInt(1 + Math.floor(rnd() * 5));
  }
  if (rnd() < 0.5) doc.customer = { id: NumberInt(1 + Math.floor(rnd() * 50000)), name: "Гість " + i };
  if (rnd() < 0.7) {
    const n = 1 + Math.floor(rnd() * 4), used = new Set();
    doc.dishes = [];
    for (let k = 0; k < n; k++) {
      const d = dishes[Math.floor(Math.pow(rnd(), 2) * dishes.length)];
      if (used.has(d._id)) continue;
      used.add(d._id);
      const item = { dishId: d._id, name: d.name, rating: NumberInt(1 + Math.floor(rnd() * 5)) };
      if (rnd() < 0.5) item.tags = [pick(TAGS), pick(TAGS)].filter((v, idx, a) => a.indexOf(v) === idx);
      doc.dishes.push(item);
    }
  }
  if (rnd() < 0.8) doc.text = pick(TEXTS);
  if (rnd() < 0.15) doc.photos = [{ url: `https://cdn.resto.ua/r/${i}/1.jpg`, w: NumberInt(1280), h: NumberInt(960) }];
  docs.push(doc);
}
db.reviews.insertMany(docs);

// --- Індекси під шаблони доступу ------------------------------------------
db.reviews.createIndex({ orderId: 1 }, { unique: true });                 // один відгук на чек
db.reviews.createIndex({ status: 1, visitAt: -1 });                       // черга модерації: рівність -> порядок
db.reviews.createIndex({ "dishes.dishId": 1, visitAt: -1 });              // multikey: відгуки про страву
db.reviews.createIndex({ text: "text" }, { default_language: "none" });   // повнотекстовий пошук

print("dishes :", db.dishes.countDocuments());
print("reviews:", db.reviews.countDocuments());
printjson(db.reviews.findOne({ dishes: { $exists: true }, "ratings.food": { $exists: true } }));
