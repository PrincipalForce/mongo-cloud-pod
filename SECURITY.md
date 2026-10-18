# Security

## Reporting a vulnerability

Report privately — do not open a public issue.

- GitHub Security Advisories: use **Report a vulnerability** on the repository's
  Security tab (preferred).
- Email: security@principalforce.com

Please include the chart version, engine, Kubernetes version, what you
observed, and a reproduction if you have one. Expect an acknowledgement within
three working days and an assessment within ten. If a fix is warranted we will
coordinate a release and credit you, unless you would rather we didn't.

### What belongs upstream

This repository is a chart and a set of manifests; it contains no database
code. Vulnerabilities in the software it deploys go to those projects:

- FerretDB — https://github.com/FerretDB/FerretDB/security
- DocumentDB — https://github.com/microsoft/documentdb/security
- PostgreSQL — https://www.postgresql.org/support/security/
- MongoDB — https://www.mongodb.com/docs/manual/administration/vulnerability-notification/

A misconfiguration *in this chart* that exposes one of those — a default that
leaves a port open, a Secret rendered where it shouldn't be — is ours, and we
want to hear about it.

## What this chart does by default

- Authentication is always on. There is no "no password" mode.
- `ClusterIP` only. Nothing is exposed outside the cluster unless you ask.
- Default-deny NetworkPolicy on 27017, allow-listed to the release's namespace.
  The storage node accepts connections only from the gateway and backup jobs.
- Non-root (uid 999), `runAsNonRoot`, all capabilities dropped, no privilege
  escalation, `RuntimeDefault` seccomp. The gateway also runs read-only-root.
- No ServiceAccount token is mounted into any database pod.
- Passwords are generated per install, stored only in a Secret, and read back
  on upgrade rather than regenerated.

## What it does not do

- **Encryption in transit between client and database.** There is no TLS
  listener. Use a service mesh (mTLS) or a sidecar. Plaintext 27017 inside the
  cluster is the default, which is fine behind a mesh and not fine across an
  untrusted network.
- **Encryption at rest.** That is your StorageClass's job; use an encrypted one.
- **Secret encryption in etcd.** Enable `EncryptionConfiguration` on your API
  server, or use External Secrets / Sealed Secrets and
  `auth.existingSecret`.
- **Audit logging.** Not available from the FerretDB engine.

## Things that will get you compromised

1. `service.type: LoadBalancer` with no `loadBalancerSourceRanges`. This puts a
   database on the internet. The chart warns in its install notes; it cannot
   stop you.
2. A password in a Git-synced manifest. Use `auth.existingSecret`. The
   production Kustomize overlay deliberately ships no Secret for this reason.
3. Assuming NetworkPolicy is enforced. It is enforced by the CNI; on a cluster
   without a policy-aware CNI these objects do nothing at all. Verify.
4. The development overlay anywhere real. Its password is in this repository.

## Verifying a release

Charts published to GHCR are signed with cosign (keyless, tied to the release
workflow's identity):

```bash
cosign verify ghcr.io/principalforce/charts/mongo-cloud-pod:0.1.0 \
  --certificate-identity-regexp '^https://github\.com/PrincipalForce/mongo-cloud-pod/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

## Supported versions

Pre-1.0: the latest minor only. Once 1.0 ships, the current and previous minor.
