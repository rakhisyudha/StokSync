# Local development database

Docker Compose provides PostgreSQL for local development only; it does not run the API or any background workers.

## Setup

1. Copy the templates:

   ```powershell
   Copy-Item .env.example .env
   Copy-Item server/.env.example server/.env
   ```

2. Replace `replace-with-a-local-dev-password` in both files with the same unique, URL-safe local password. In `server/.env`, also replace the authentication secret placeholder with a random value of at least 32 bytes. The templates contain placeholders only and must not receive production credentials.
3. Start PostgreSQL and wait for its health check:

   ```powershell
   docker compose up -d postgres
   docker compose ps
   ```

4. Apply the SQL migrations with the pinned `golang-migrate` container:

   ```powershell
   docker compose --profile tools run --rm migrate
   ```

   The runner reads the versioned SQL files in `server/migrations` and records applied versions in PostgreSQL. After applying them, use the smoke check in [`server/migrations/README.md`](../server/migrations/README.md) to verify the expected tables and seeded synchronization cursor.

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
