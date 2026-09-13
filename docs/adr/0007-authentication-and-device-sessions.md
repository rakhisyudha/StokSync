# ADR 0007: Signed access tokens and hashed rotating refresh sessions

## Status

Accepted

## Context

StokSync must support an offline-first client without making long-lived bearer
credentials easy to replay. Each authenticated installation has a durable
client-generated device UUID, while the API must retain account/device
ownership boundaries and make lost responses safe to retry.

## Decision

- Passwords are hashed with bcrypt using an adaptive deployment-configured cost
  (12 by default). Passwords and hashes are never written to logs or returned
  in API errors.
- Access tokens are short-lived HS256 JWTs. They include issuer, audience,
  account subject, device UUID, token id, issue time, expiry, and an explicit
  access-token use claim. The signing secret is mandatory at service startup,
  must be at least 32 bytes, and is loaded from deployment configuration.
- Refresh tokens are cryptographically random opaque values. PostgreSQL stores
  only a SHA-256 digest, never the bearer value. A refresh transaction locks the
  digest row, marks it revoked/rotated, and inserts its replacement before
  commit.
- A reused, expired, or explicitly revoked refresh token cannot mint a new
  session. Reuse detection revokes all still-active refresh tokens for that
  account/device, retaining rows for auditability.
- Chi middleware validates the access signature and claims before adding a
  typed account/device identity to request context. Authentication failures
  return a generic response and never log token or credential material.

## Consequences

Access-token validation is stateless and naturally expires without a database
lookup; refresh-session revocation remains durable and transaction-safe. A
signing-secret rotation requires an application-wide deployment decision (or a
future key-id/key-ring extension). The API exposes registration, login,
refresh, and authenticated device logout; product and sync authorization will
reuse the same middleware in later milestones.
