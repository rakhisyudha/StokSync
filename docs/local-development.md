# Local development database

Docker Compose provides PostgreSQL for local development only; it does not run the API or any background workers.

## Setup

1. Copy the templates:

   ```powershell
   Copy-Item .env.example .env
   Copy-Item server/.env.example server/.env
   ```

2. Replace `replace-with-a-local-dev-password` in both files with the same unique, URL-safe local password. The templates contain placeholders only and must not receive production credentials.
3. Start PostgreSQL and wait for its health check:

   ```powershell
   docker compose up -d postgres
   docker compose ps
   ```

4. Apply the SQL migrations with the pinned `golang-migrate` container:

   ```powershell
   docker compose --profile tools run --rm migrate
   ```

   The runner reads `server/migrations`. It is intentionally empty until schema migrations are introduced; running it before then completes with no schema changes.

## Useful commands

```powershell
# Follow PostgreSQL logs.
docker compose logs -f postgres

# Stop the local services while preserving database data.
docker compose down

# Remove local services and the development database volume.
docker compose down -v
```

`docker compose down -v` permanently deletes the local PostgreSQL data volume.
