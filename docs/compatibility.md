# Compatibility

What works, what doesn't, and how to find out before you migrate.

This page is about the **default `ferretdb` engine**. The `mongodb-community`
engine is MongoDB, so its compatibility with MongoDB is total; the trade you
make there is [licensing](licensing.md), not features.

## Decide in two minutes

Run this against your existing MongoDB and read the output:

```bash
# Which commands does your application actually use?
mongosh "<your-connection-string>" --quiet --eval '
  const s = db.serverStatus().metrics.commands;
  Object.entries(s)
    .filter(([k, v]) => v.total > 0 && k !== "<UNKNOWN>")
    .sort((a, b) => b[1].total - a[1].total)
    .forEach(([k, v]) => print(v.total.toString().padStart(12), k));
'
```

If `getMore`, `find`, `insert`, `update`, `delete`, `aggregate` and
`createIndexes` dominate and nothing in the **Not supported** table below
appears, you are in the comfortable majority. If `aggregate` is large, check
which stages — see the pipeline list below.

## Supported

Verified by `scripts/smoke-test.sh` and the chart's `helm test` hook on every
CI run.

| Area | Notes |
| --- | --- |
| Wire protocol | MongoDB 5.0+ (`OP_MSG`). Drivers negotiate normally. |
| Authentication | `SCRAM-SHA-256`. Credentials map to a Postgres role. |
| CRUD | `insertOne/Many`, `find`, `updateOne/Many`, `replaceOne`, `deleteOne/Many`, `findAndModify`, upserts, bulk writes. |
| Query operators | Comparison, logical, element, array (`$elemMatch`, `$all`, `$size`), `$regex`, dotted paths into nested documents. |
| Update operators | `$set`, `$unset`, `$inc`, `$mul`, `$min`, `$max`, `$rename`, `$push`, `$pull`, `$addToSet`, `$pop`, `$currentDate`. |
| Indexes | Single-field, compound, multikey (arrays), unique, partial, TTL, text, and vector (via DocumentDB). |
| Aggregation | `$match`, `$project`, `$group`, `$sort`, `$limit`, `$skip`, `$unwind`, `$lookup`, `$addFields`/`$set`, `$count`, `$facet`, `$replaceRoot`, `$sample`, accumulators. |
| Cursors | `getMore`, batch sizes, `tailable` on capped collections is *not* included — see below. |
| Transactions | Multi-document, single-node semantics. |
| Admin | `listDatabases`, `listCollections`, `collStats`, `dbStats`, `createIndexes`, `dropIndexes`, `explain` (plan shape differs). |

## Not supported

Hitting one of these is a hard failure, not a slow path. Check this list before
migrating.

| Feature | Why | Workaround |
| --- | --- | --- |
| **Change streams** (`watch()`) | Depends on MongoDB's oplog, which has no equivalent here. | Postgres `LISTEN/NOTIFY` or logical replication at the storage layer; or an outbox table your application writes to. |
| **Sharding** (`mongos`, shard keys) | No sharding layer. Vertical scale and Postgres partitioning only. | Partition at the application level, or scale the storage node up. |
| `$out`, `$merge` | Aggregation stages that write back to collections. | Read results and write them with an ordinary `insertMany`. |
| **GridFS** | No server-side GridFS support. | Object storage (S3/MinIO) for blobs, which is the better design anyway. |
| **Server-side JavaScript** (`$where`, `mapReduce`, `$function`) | No JS engine in the data path. | Rewrite as an aggregation pipeline, or do it in your application. |
| **Capped collections / tailable cursors** | No capped collection implementation. | A TTL index plus a normal cursor covers most uses. |
| **Replica set topology commands** (`rs.status()`, read preferences) | A single logical node; the driver sees a standalone. | Use Postgres replication for HA; it is invisible to the driver. |
| **Atlas-specific features** (Search, Vector Search API, Triggers, Realm) | Proprietary cloud services, not server features. | Postgres full-text search, or `pgvector` via DocumentDB's vector index. |

## Partially supported

Works, but not identically. Test these rather than assuming.

| Feature | Difference |
| --- | --- |
| Transactions | Supported within the single storage node. No retryable writes, no cross-shard semantics (there are no shards). Long transactions hold Postgres locks — keep them short. |
| `explain` | Returns a plan, but its shape is Postgres-derived and does not match MongoDB's `winningPlan` structure. Tools that parse `explain` output will need adjusting. |
| Collation | Limited locale support. Default binary collation behaves as expected; locale-specific ordering may differ. |
| `$lookup` | Works for ordinary joins. Deeply nested or correlated pipelines can be markedly slower than on MongoDB. |
| Text search | `$text` is backed by Postgres full-text search. Scoring and stemming differ from MongoDB's. |
| Decimal128 | Stored and returned, but arithmetic edge cases can differ from MongoDB's implementation. |
| Error codes | Most common codes match. Rarely-hit codes may differ, so match on behaviour rather than exact codes where you can. |

## Performance

Expect broadly comparable throughput for point reads, indexed queries and
writes — DocumentDB stores BSON in Postgres with purpose-built index types, not
as a naive JSONB translation layer. Where the profile differs:

- **Large aggregation pipelines** translate to SQL and can be slower or faster
  depending on shape; `$lookup`-heavy pipelines are the usual slow case.
- **Write-heavy bulk loads** go through Postgres' WAL, so they benefit from the
  same tuning any Postgres write workload does (see the production overlay).
- **Connection handling** is Postgres', not MongoDB's. The gateway pools, but a
  client opening thousands of connections needs `max_connections` raised.

Benchmark with your own workload. A generic number here would be worth less
than ten minutes with your real queries.

## Verifying against your application

The honest test is your own test suite pointed at a local instance:

```bash
docker compose up -d
# then run your application's integration tests against:
#   mongodb://mongouser:localdevpassword@localhost:27017/appdb
```

If you want to compare behaviour side by side with real MongoDB:

```bash
docker compose down
docker compose --profile mongodb-community up -d   # same port, same credentials
# run the same tests again and diff the results
```

That comparison is the main reason the SSPL engine exists in this repository.

## Reporting a gap

If something in **Supported** doesn't work, that is a bug here — open an issue
with the smallest `mongosh` snippet that reproduces it. If something in **Not
supported** is blocking you, say so in an issue anyway: upstream FerretDB
prioritises by demand, and the gap list moves.
