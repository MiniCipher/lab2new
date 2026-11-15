// =====================================================================
// ЛР2, частина 6 — базові запити MongoDB (після 01_setup.js)
//   mongosh "mongodb://localhost:27017" mongo/02_queries.js
// =====================================================================
db = db.getSiblingDB("restaurant_docs");
const h = t => print("\n==== " + t + " " + "=".repeat(Math.max(0, 60 - t.length)));

// ---------------------------------------------------------------- CREATE
h("1. insertOne: новий відгук із QR-меню (з деталізацією по стравах)");
const ins = db.reviews.insertOne({
  orderId: NumberLong("999001"), tableNo: NumberInt(7), visitAt: new Date(), channel: "qr",
  customer: { id: NumberInt(1), name: "Петро Іваненко" },
  ratings: { overall: NumberInt(5), food: NumberInt(5), service: NumberInt(4) },
  dishes: [
    { dishId: NumberInt(2), name: "Курча по-київськи", rating: NumberInt(5), tags: ["гаряче", "велика порція"] },
    { dishId: NumberInt(4), name: "Тірамісу", rating: NumberInt(4) }
  ],
  text: "Курча неймовірне, тірамісу трохи солодке", status: "new",
  helpful: NumberInt(0), schemaVersion: NumberInt(1)
});
printjson(ins);

h("2. Повторний відгук на той самий чек -> конфлікт унікального індексу");
try {
  db.reviews.insertOne({ orderId: NumberLong("999001"), visitAt: new Date(), channel: "staff",
                         ratings: { overall: NumberInt(3) }, status: "new", schemaVersion: NumberInt(1) });
} catch (e) { print("Очікувана помилка:", e.code, e.codeName || ""); }

h("3. Документ, що порушує $jsonSchema (оцінка 7) -> відхилено валідатором");
try {
  db.reviews.insertOne({ orderId: NumberLong("999002"), visitAt: new Date(), channel: "qr",
                         ratings: { overall: NumberInt(7) }, status: "new", schemaVersion: NumberInt(1) });
} catch (e) { print("Очікувана помилка:", e.code, e.codeName || "", "(Document failed validation)"); }

h("4. insertMany: відгуки від офіціанта (без деталізації — інша форма документа)");
printjson(db.reviews.insertMany([
  { orderId: NumberLong("999003"), tableNo: NumberInt(12), visitAt: new Date(), channel: "staff",
    ratings: { overall: NumberInt(4) }, text: "Гості просили тихішу музику", status: "new",
    helpful: NumberInt(0), schemaVersion: NumberInt(1) },
  { orderId: NumberLong("999004"), tableNo: NumberInt(3), visitAt: new Date(), channel: "google",
    ratings: { overall: NumberInt(2), service: NumberInt(1) }, text: "Довго чекали рахунок",
    status: "new", helpful: NumberInt(0), schemaVersion: NumberInt(1) }
]).insertedIds);

// ---------------------------------------------------------------- READ
h("5. findOne за ключем (orderId)");
printjson(db.reviews.findOne({ orderId: NumberLong("999001") }, { _id: 0, orderId: 1, ratings: 1, dishes: 1 }));

h("6. Фільтр + проєкція + сортування + ліміт: нові негативні відгуки (черга модерації)");
db.reviews.find(
  { status: "new", "ratings.overall": { $lte: 2 } },
  { _id: 0, orderId: 1, visitAt: 1, "ratings.overall": 1, text: 1 }
).sort({ visitAt: -1, _id: 1 }).limit(5).forEach(printjson);

h("7. Пошук по вкладеному масиву: відгуки, де ТА САМА позиція — «Піца Маргарита» з оцінкою <= 2 ($elemMatch)");
print("з $elemMatch :", db.reviews.countDocuments({ dishes: { $elemMatch: { dishId: 3, rating: { $lte: 2 } } } }));
print("без $elemMatch (умови можуть збігтися в РІЗНИХ елементах):",
      db.reviews.countDocuments({ "dishes.dishId": 3, "dishes.rating": { $lte: 2 } }));

h("8. Оператори $exists / $in / $size: відгуки з фото з Google або QR, де оцінено рівно 2 страви");
print(db.reviews.countDocuments({ photos: { $exists: true }, channel: { $in: ["google", "qr"] },
                                  dishes: { $size: 2 } }));

h("9. Повнотекстовий пошук ($text): «довго чекали»");
db.reviews.find({ $text: { $search: "довго чекали" } }, { _id: 0, orderId: 1, text: 1, score: { $meta: "textScore" } })
  .sort({ score: { $meta: "textScore" } }).limit(3).forEach(printjson);

h("10. distinct: які канали надходження відгуків існують");
printjson(db.reviews.distinct("channel"));

// ---------------------------------------------------------------- UPDATE
h("11. updateOne з $set + $push: адміністратор відповів на відгук");
printjson(db.reviews.updateOne(
  { orderId: NumberLong("999004"), status: "new" },
  { $set: { status: "answered", reply: { by: "Олена Коваленко", at: new Date(), text: "Вибачте, вже працюємо над швидкістю" } },
    $push: { "history": { at: new Date(), action: "reply" } } }
));

h("12. Атомарний лічильник $inc: «відгук корисний»");
printjson(db.reviews.updateOne({ orderId: NumberLong("999001") }, { $inc: { helpful: 1 } }));

h("13. Оптимістичний контроль: змінюємо лише якщо статус досі 'new' (повтор дає modifiedCount=0)");
printjson(db.reviews.updateOne({ orderId: NumberLong("999004"), status: "new" }, { $set: { status: "hidden" } }));

h("14. Оновлення елемента масиву позиційним оператором $: додати тег до страви 4 у відгуку 999001");
printjson(db.reviews.updateOne({ orderId: NumberLong("999001"), "dishes.dishId": 4 },
                               { $addToSet: { "dishes.$.tags": "солодке" } }));

h("15. updateMany: приховати відгуки зі скаргою на рахунок старші за дату (масова модерація)");
printjson(db.reviews.updateMany({ channel: "google", "ratings.overall": 1, visitAt: { $lt: new Date("2026-03-01") } },
                                { $set: { status: "hidden" } }));

h("16. Еволюція схеми: v1 -> v2 (додаємо поле sentiment, міграція ідемпотентна)");
printjson(db.reviews.updateMany(
  { schemaVersion: 1 },
  [{ $set: { schemaVersion: NumberInt(2),
             sentiment: { $switch: { branches: [
               { case: { $gte: ["$ratings.overall", 4] }, then: "positive" },
               { case: { $lte: ["$ratings.overall", 2] }, then: "negative" }], default: "neutral" } } } }]
));

// ---------------------------------------------------------------- AGGREGATION
h("17. Агрегація: середня оцінка та кількість відгуків по стравах ($unwind -> $group -> $sort)");
db.reviews.aggregate([
  { $match: { status: { $ne: "hidden" } } },
  { $unwind: "$dishes" },
  { $group: { _id: "$dishes.dishId", reviews: { $sum: 1 }, avgRating: { $avg: "$dishes.rating" } } },
  { $match: { reviews: { $gte: 20 } } },
  { $sort: { avgRating: -1, _id: 1 } },
  { $limit: 5 },
  // поточна назва з каталогу (а в самому відгуку зберігається історичний знімок)
  { $lookup: { from: "dishes", localField: "_id", foreignField: "_id", as: "dish" } },
  { $project: { _id: 0, dishId: "$_id", name: { $first: "$dish.name" }, reviews: 1,
                avgRating: { $round: ["$avgRating", 2] } } }
]).forEach(printjson);

h("18. Агрегація: NPS-подібна динаміка по місяцях і каналах");
db.reviews.aggregate([
  { $group: { _id: { month: { $dateToString: { format: "%Y-%m", date: "$visitAt" } }, channel: "$channel" },
              n: { $sum: 1 },
              promoters: { $sum: { $cond: [{ $eq: ["$ratings.overall", 5] }, 1, 0] } },
              detractors: { $sum: { $cond: [{ $lte: ["$ratings.overall", 2] }, 1, 0] } } } },
  { $project: { _id: 0, month: "$_id.month", channel: "$_id.channel", n: 1,
                score: { $round: [{ $multiply: [{ $divide: [{ $subtract: ["$promoters", "$detractors"] }, "$n"] }, 100] }, 1] } } },
  { $sort: { month: 1, channel: 1 } },
  { $limit: 6 }
]).forEach(printjson);

h("19. $facet: зведення для дашборду одним запитом");
printjson(db.reviews.aggregate([
  { $facet: {
      byStatus: [{ $group: { _id: "$status", n: { $sum: 1 } } }, { $sort: { _id: 1 } }],
      ratingHistogram: [{ $bucket: { groupBy: "$ratings.overall", boundaries: [1, 2, 3, 4, 5, 6], output: { n: { $sum: 1 } } } }],
      topTags: [{ $unwind: "$dishes" }, { $unwind: "$dishes.tags" },
                { $group: { _id: "$dishes.tags", n: { $sum: 1 } } }, { $sort: { n: -1 } }, { $limit: 3 }]
  } }
]).toArray()[0]);

// ---------------------------------------------------------------- INDEX / EXPLAIN
h("20. explain: черга модерації використовує індекс {status, visitAt}");
const ex = db.reviews.find({ status: "new" }).sort({ visitAt: -1 }).limit(20).explain("executionStats");
printjson({ winningStage: ex.queryPlanner.winningPlan.stage || ex.queryPlanner.winningPlan.queryPlan?.stage,
            nReturned: ex.executionStats.nReturned, totalKeysExamined: ex.executionStats.totalKeysExamined,
            totalDocsExamined: ex.executionStats.totalDocsExamined,
            executionTimeMillis: ex.executionStats.executionTimeMillis });

h("21. Для порівняння — той самий запит із примусовим повним проходом колекції ($natural)");
const ex2 = db.reviews.find({ status: "new" }).sort({ visitAt: -1 }).limit(20).hint({ $natural: 1 }).explain("executionStats");
printjson({ totalKeysExamined: ex2.executionStats.totalKeysExamined, totalDocsExamined: ex2.executionStats.totalDocsExamined,
            executionTimeMillis: ex2.executionStats.executionTimeMillis });

// ---------------------------------------------------------------- DELETE
h("22. deleteOne / deleteMany (лише навчальні документи цього скрипта)");
printjson(db.reviews.deleteOne({ orderId: NumberLong("999003") }));
printjson(db.reviews.deleteMany({ orderId: { $in: [NumberLong("999001"), NumberLong("999002"), NumberLong("999004")] } }));
print("reviews після очищення:", db.reviews.countDocuments());
