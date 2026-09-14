# Safe diagnostics

StokSync emits structured JSON diagnostics for server HTTP/auth/sync events and for client login/sync-trigger events. Diagnostics are operational summaries, not request tracing payloads.

Safe fields include event name, bounded status/count fields, sync outcome/reason, route method/path, duration, and a generated request ID. Passwords, access tokens, refresh tokens, bearer/authorization values, cookies, credentials, request/response bodies, and full domain payloads are never emitted. Arbitrary errors and objects are represented by their type only; untrusted request IDs are replaced before logging. Client diagnostic output is best-effort and debug-only by default, and its writer cannot change application behavior.

When adding an event, pass stable codes and counts rather than request data. Do not add an email, token, header, payload, or raw exception string to diagnostic fields. The redaction helpers and focused tests in `server/internal/platform/logging` and `app/test/core/diagnostics` define the safe boundary.
