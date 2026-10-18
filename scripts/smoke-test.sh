#!/usr/bin/env bash
# End-to-end smoke test against a running mongo-cloud-pod.
#
#   ./scripts/smoke-test.sh "mongodb://mongouser:localdevpassword@localhost:27017/appdb"
#   ./scripts/smoke-test.sh                 # defaults to the compose stack
#
# Exercises what an application actually does — insert, index, query,
# aggregate, update, delete — rather than checking that a port is open. CI runs
# this against both engines, which is how an engine-specific regression in the
# chart gets caught before a user finds it.
set -euo pipefail

CONN="${1:-mongodb://${MONGO_USERNAME:-mongouser}:${MONGO_PASSWORD:-localdevpassword}@localhost:${MONGO_PORT:-27017}/${MONGO_DATABASE:-appdb}}"

if ! command -v mongosh >/dev/null 2>&1; then
  echo "mongosh not found. Either install it, or run the same checks through" >&2
  echo "the chart's test hook:  helm test <release> -n <namespace>" >&2
  exit 127
fi

echo "→ connecting to ${CONN//:*@/:***@}"

mongosh "${CONN}" --quiet --eval '
  const coll = db.smokeTest;
  coll.drop();

  // ── insert ────────────────────────────────────────────────────────────────
  const docs = [];
  for (let i = 0; i < 1000; i++) {
    docs.push({ i, team: i % 3 === 0 ? "a" : "b", nested: { v: i * 2 }, tags: ["x", `t${i % 5}`] });
  }
  coll.insertMany(docs);
  assert.strictEqual(coll.countDocuments({}), 1000, "insertMany/count mismatch");

  // ── indexes ───────────────────────────────────────────────────────────────
  // Index creation touches the storage layer, not just the wire protocol, and
  // is the first thing to fail on a half-installed DocumentDB extension.
  coll.createIndex({ team: 1, i: -1 });
  coll.createIndex({ "nested.v": 1 });
  coll.createIndex({ tags: 1 });
  assert(coll.getIndexes().length >= 4, "expected 3 indexes plus _id");

  // ── query ─────────────────────────────────────────────────────────────────
  assert.strictEqual(coll.countDocuments({ team: "a" }), 334, "filter count mismatch");
  assert.strictEqual(coll.countDocuments({ "nested.v": { $lt: 10 } }), 5, "nested range mismatch");
  assert.strictEqual(coll.countDocuments({ tags: "t3" }), 200, "array membership mismatch");
  assert.strictEqual(coll.find({ i: { $gte: 990 } }).sort({ i: 1 }).toArray().length, 10, "sort/limit mismatch");

  // ── aggregate ─────────────────────────────────────────────────────────────
  const agg = coll.aggregate([
    { $match: { team: "a" } },
    { $group: { _id: "$team", total: { $sum: "$i" }, n: { $sum: 1 } } },
  ]).toArray();
  assert.strictEqual(agg[0].n, 334, "aggregation group count mismatch");

  const unwound = coll.aggregate([
    { $unwind: "$tags" },
    { $group: { _id: "$tags", n: { $sum: 1 } } },
    { $sort: { _id: 1 } },
  ]).toArray();
  assert.strictEqual(unwound.length, 6, "unwind produced unexpected tag cardinality");

  // ── update / delete ───────────────────────────────────────────────────────
  const upd = coll.updateMany({ team: "a" }, { $inc: { "nested.v": 1 } });
  assert.strictEqual(upd.modifiedCount, 334, "updateMany mismatch");
  assert.strictEqual(coll.deleteMany({ team: "b" }).deletedCount, 666, "deleteMany mismatch");
  assert.strictEqual(coll.countDocuments({}), 334, "post-delete count mismatch");

  coll.drop();
  print("✓ mongo-cloud-pod smoke test passed");
'
