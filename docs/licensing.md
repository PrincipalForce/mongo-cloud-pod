# Licensing

> This document explains the engineering decisions behind this project's
> licence choices. It is not legal advice. If your situation is commercially
> significant, read the licences yourself and talk to a lawyer.

## The short version

You cannot make MongoDB open source. Its licence is MongoDB Inc.'s to choose,
and since version 4.0 that choice has been the **Server Side Public License**.
No wrapper, chart, or repository changes that.

What you *can* do is pick what sits behind the wire protocol. That is the only
real decision here, and this project makes both options explicit:

| | `engine: ferretdb` (default) | `engine: mongodb-community` |
| --- | --- | --- |
| What runs | FerretDB → Postgres + DocumentDB | `mongod` |
| Licences | Apache-2.0, MIT, PostgreSQL | SSPL-1.0 |
| OSI-approved | Yes | No |
| Cost | Free | Free |
| Offer as a service to third parties | Yes | Not without SSPL §13 obligations |
| MongoDB feature coverage | High, with gaps ([compatibility](compatibility.md)) | Complete |
| Gated in this chart | No | Yes — `sspl.acknowledged: true` |

## What the SSPL actually says

The clause that matters is §13, *Offering the Program as a Service*:

> If you make the functionality of the Program or a modified version available
> to third parties as a service, you must make the Service Source Code
> available […] under the terms of this License.

"Service Source Code" is defined expansively: not just your modifications, but
the management software, APIs, monitoring, provisioning and orchestration
tooling that makes the service work. For a platform that provisions databases,
that reaches the platform itself.

Three things follow:

1. **SSPL is free of charge.** People sometimes assume "not open source" means
   "you have to pay". You don't. Self-hosting MongoDB Community costs nothing.
2. **SSPL is fine for first-party use.** Running a database for your own
   application — even a commercial, closed-source one — does not trigger §13.
   You are not offering the database's functionality to third parties; you are
   using it to build something else.
3. **SSPL is not viable for a database-as-a-service.** If your users get a
   database, §13 is pointed directly at you. This is intentional on MongoDB
   Inc.'s part; it is what the licence was written to do.

The OSI declined to approve the SSPL, and Debian, Fedora and Red Hat removed
MongoDB from their distributions over it. That is the practical meaning of "not
open source" here: the ecosystem treats it as proprietary-with-source.

## Why not just ship an old MongoDB?

MongoDB 3.6 and 4.0.x were AGPL-3.0, which *is* OSI-approved, and relicensing
is not retroactive — those releases remain AGPL. So why not pin to 4.0?

Because they stopped receiving security patches in April 2020 and April 2022
respectively. Shipping a database with six years of unpatched CVEs to solve a
licensing problem trades a legal risk for a worse operational one. It is a real
option and this project deliberately declines it.

## What the default engine actually is

```
your application
      │  MongoDB wire protocol, port 27017
      ▼
FerretDB                        Apache-2.0
      │  SQL, port 5432
      ▼
PostgreSQL + DocumentDB         PostgreSQL licence + MIT
```

FerretDB is a protocol translator: it parses MongoDB wire messages, executes
them against Postgres, and serializes MongoDB-shaped responses. Since FerretDB
2.x, the document storage, BSON type system, indexing and aggregation
primitives live in **DocumentDB**, a Postgres extension originally written and
open-sourced by Microsoft under MIT, now developed under the Linux Foundation.

None of those three licences restricts the field of use, so a deployment can be
offered as a managed service. All three are OSI-approved or equivalent
(the PostgreSQL licence is a BSD/MIT-style permissive licence).

## Trademarks are a separate question from licences

MONGODB is a registered trademark of MongoDB, Inc. Compatibility with a
protocol is not permission to use a name. That is why this project:

- is called `mongo-cloud-pod`, describing what it does, not `OpenMongoDB`;
- describes itself as "MongoDB-compatible", a factual claim about wire
  protocol and driver support;
- does not claim affiliation, endorsement or sponsorship;
- carries the disclaimer in [`NOTICE`](../NOTICE).

If you fork or rebrand this, keep that distinction. A permissive licence on the
software says nothing about the right to use someone else's name.

## How the gate works

Setting `engine: mongodb-community` without `sspl.acknowledged: true` fails the
render with an explanation rather than deploying:

```console
$ helm install pod charts/mongo-cloud-pod --set engine=mongodb-community
Error: mongo-cloud-pod: engine "mongodb-community" requires sspl.acknowledged=true.
…
```

This is not a legal mechanism — a value in a YAML file does not bind anyone to
anything. It is an engineering one, with two purposes:

- **Nobody deploys SSPL by accident.** The failure arrives at install time,
  while someone is reading the output, rather than at an audit two years later.
- **It is greppable afterwards.** SSPL workloads carry
  `mongo-cloud-pod.io/license: SSPL-1.0` and
  `mongo-cloud-pod.io/engine: mongodb-community` as labels, so across a fleet:

  ```bash
  kubectl get pods -A -l mongo-cloud-pod.io/engine=mongodb-community
  ```

  answers "where are we running SSPL?" in one command.

`scripts/verify-licenses.sh` enforces the other half in CI: a default render
must contain no MongoDB Inc. server image, and the gate must still reject an
unacknowledged SSPL install. Both run again at release time, so a tag pushed
past CI still cannot publish an SSPL default.

## This project's own licence

Apache-2.0. Permissive, patent-granting, and compatible with being vendored
into a commercial platform — including one that offers databases as a service,
which is the use case that motivated it.

## Sources

- [SSPL text](https://www.mongodb.com/licensing/server-side-public-license)
- [SSPL FAQ (MongoDB Inc.)](https://www.mongodb.com/licensing/server-side-public-license/faq)
- [OSI on the SSPL](https://opensource.org/blog/the-sspl-is-not-an-open-source-license)
- [FerretDB licence](https://github.com/FerretDB/FerretDB/blob/main/LICENSE)
- [DocumentDB licence](https://github.com/microsoft/documentdb/blob/main/LICENSE)
- [PostgreSQL licence](https://www.postgresql.org/about/licence/)
