# Deployment: VPS backend and Android release

This guide covers taking the StokSync API to a VPS with Docker, and building/releasing the Flutter client against that deployed API. It assumes the [local development setup](local-development.md) already works for you.

## 1. Backend: deploy the API on a VPS with Docker

### 1.1 What ships in the image

`server/Dockerfile` is a multi-stage build: a `golang:1.23-alpine` stage compiles a static, `CGO_ENABLED=0` binary, and the final `alpine:3.20` runtime stage contains only that binary, CA certificates, and a non-root `stoksync` user. The image declares `HEALTHCHECK` against `GET /v1/health` and defaults to listening on `:8080` (controlled by `STOKSYNC_HTTP_ADDR` at runtime).

`docker-compose.prod.yml` runs three services: `postgres` (data volume, no host-published port), `migrate` (one-shot, applies `server/migrations` and exits), and `api` (built from `server/Dockerfile`, depends on `migrate` completing successfully). Only the API port is published to the host; PostgreSQL is reachable only on the internal `stoksync-internal` Docker network. This has been verified locally end to end: both containers report `healthy`, and `/v1/health` and `/v1/ready` respond correctly through the published port.

### 1.2 Prerequisites on the VPS

- A VPS with Docker Engine and the Docker Compose plugin installed (`docker compose version` should work; most current distributions install both together via Docker's official install script).
- A domain name (or subdomain) pointed at the VPS's public IP, if you want a real HTTPS certificate. You can deploy without one, but every mobile client would then need to trust a self-signed certificate or use plain HTTP, which the client code accepts (`STOKSYNC_API_BASE_URL` allows `http://`) but is not recommended beyond local testing.
- Inbound firewall rules allowing 80/443 (for the reverse proxy) and SSH; the API's own port (`8080` by default) does not need to be open to the internet if a reverse proxy terminates TLS and proxies to it over `localhost`.

### 1.3 Get the code onto the VPS

```bash
git clone <your-repository-url> stoksync
cd stoksync
```

Only `server/`, `docker-compose.prod.yml`, `.env.prod.example`, and `server/migrations` are needed on the VPS; the Flutter app is built on your workstation, not the server.

### 1.4 Configure production environment values

```bash
cp .env.prod.example .env.prod
```

Edit `.env.prod` and replace every placeholder:

- `POSTGRES_PASSWORD`: a long random value, unique to this deployment. Generate one with `openssl rand -base64 32`.
- `STOKSYNC_AUTH_ACCESS_TOKEN_SECRET`: at least 32 random bytes. Generate one with `openssl rand -base64 48`.
- `STOKSYNC_API_PORT`: the local port the API binds to on the VPS host (default `8080`). Keep this as a `localhost`-only bind if you're using a reverse proxy (see 1.6).

`.env.prod` is already covered by `.gitignore` (matches the `.env.*` pattern) — never commit it. `.env.prod.example` is the only file meant to be shared/committed.

### 1.5 Build and start the stack

```bash
docker compose --env-file .env.prod -f docker-compose.prod.yml up -d --build
docker compose -f docker-compose.prod.yml ps
```

Both `postgres` and `api` should report `healthy`. Confirm the API responds:

```bash
curl http://127.0.0.1:8080/v1/health
curl http://127.0.0.1:8080/v1/ready
```

`/v1/ready` returning `{"status":"ready"}` confirms the API successfully reached PostgreSQL, not just that the process started.

To view logs or stop the stack:

```bash
docker compose -f docker-compose.prod.yml logs -f api
docker compose --env-file .env.prod -f docker-compose.prod.yml down
```

`down` alone preserves the `stoksync-postgres-data` volume; add `-v` only if you intentionally want to discard the database.

### 1.6 Put TLS in front of the API (required for a real deployment)

The API itself serves plain HTTP; it has no built-in TLS termination, matching design.md's decision to keep the API's own responsibility narrow. Terminate TLS with a reverse proxy in front of it. The two common choices:

**Caddy** (simplest — automatic Let's Encrypt certificates):

```caddyfile
# /etc/caddy/Caddyfile
api.yourdomain.com {
    reverse_proxy 127.0.0.1:8080
}
```

```bash
sudo systemctl reload caddy
```

**nginx** (if you already run nginx):

```nginx
server {
    listen 443 ssl;
    server_name api.yourdomain.com;

    ssl_certificate     /etc/letsencrypt/live/api.yourdomain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/api.yourdomain.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

Obtain the certificate with `certbot --nginx -d api.yourdomain.com` (from the `certbot` package) before reloading nginx.

Either way, your Flutter client's `STOKSYNC_API_BASE_URL` becomes `https://api.yourdomain.com` once this is in place — never ship a release build pointed at a plain-HTTP origin.

### 1.7 Applying schema changes later

`migrate` only runs once at `docker compose up`. After pulling new commits with additional migration files, re-run just that service:

```bash
git pull
docker compose --env-file .env.prod -f docker-compose.prod.yml up -d --build migrate api
```

This rebuilds the API image (in case the migration change is paired with server code changes) and re-runs `migrate`, which is idempotent — `golang-migrate` only applies versions it hasn't already recorded.

### 1.8 Backups

`stoksync-postgres-data` is a named Docker volume. A minimal backup approach:

```bash
docker compose -f docker-compose.prod.yml exec -T postgres \
  pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB" > "stoksync-$(date +%F).sql"
```

Automate this with a cron job and copy the dump off the VPS (object storage, another host, etc.). Restoring the same way a fresh v1 deployment would apply migrations: create the database, run `migrate up`, then `psql < backup.sql`.

## 2. Android release

### 2.1 Point the release build at your deployed API

The client reads its API origin from a compile-time define, not a runtime setting (see `app/lib/core/config/app_config.dart`):

```powershell
flutter build apk --release --dart-define=STOKSYNC_API_BASE_URL=https://api.yourdomain.com
```

or, for a Play Store upload, build an app bundle instead of an APK:

```powershell
flutter build appbundle --release --dart-define=STOKSYNC_API_BASE_URL=https://api.yourdomain.com
```

If you omit `--dart-define`, the build falls back to `http://127.0.0.1:8080`, which will not work on a real device. Double-check the URL is reachable and HTTPS before distributing a build.

### 2.2 Set your own application id (required before any release)

`app/android/app/build.gradle.kts` currently ships Flutter's placeholder:

```kotlin
applicationId = "com.example.stoksync"
```

Change this to your own reverse-domain identifier (for example `com.yourcompany.stoksync`) before your first release. The Play Store treats the application id as permanent for a given listing — you cannot change it after publishing without creating a new app.

### 2.3 Configure release signing (required — do not ship the debug key)

The same file currently signs release builds with the debug keystore:

```kotlin
buildTypes {
    release {
        // TODO: Add your own signing config for the release build.
        signingConfig = signingConfigs.getByName("debug")
    }
}
```

Generate a real upload keystore once:

```powershell
keytool -genkey -v -keystore upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

Store it outside the repository. Create `app/android/key.properties` (already outside the tracked repo — add `key.properties` to `app/android/.gitignore` alongside the existing entries if it isn't already covered, and never commit the keystore itself):

```properties
storePassword=<keystore password>
keyPassword=<key password>
keyAlias=upload
storeFile=<absolute path to upload-keystore.jks>
```

Then reference it in `build.gradle.kts`:

```kotlin
import java.util.Properties
import java.io.FileInputStream

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    // ...
    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String?
            keyPassword = keystoreProperties["keyPassword"] as String?
            storeFile = keystoreProperties["storeFile"]?.let { file(it) }
            storePassword = keystoreProperties["storePassword"] as String?
        }
    }
    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}
```

Losing this keystore means you can never update the same Play Store listing again, so back it up somewhere durable and separate from this repository.

### 2.4 Distribution options

**Google Play (recommended for real users):**

1. Create a Play Console account (one-time developer registration fee).
2. Create an app listing, complete the store listing content, content rating questionnaire, and data-safety form (StokSync stores email/password for auth and inventory data — declare accordingly).
3. Upload the `appbundle` built in 2.1 to an internal testing track first.
4. Promote to closed/open testing, then production, once you're satisfied.

**Direct APK distribution (fastest for personal/demo use, e.g. sharing with the two devices for the convergence demo):**

1. Build the release APK as in 2.1 (`flutter build apk --release --dart-define=...`).
2. The output is at `app/build/app/outputs/flutter-apk/app-release.apk`.
3. Transfer it to the device (file share, USB, or any hosting you control) and install with "install from unknown sources" allowed. This is fine for personal devices; it is not a substitute for Play Store distribution to other users, since there is no update mechanism.

### 2.5 Before releasing, re-run verification

```powershell
make verify
```

This runs client and server formatting, static analysis, and tests. For the two-device demonstration specifically against the deployed VPS API rather than local Postgres, see [`README.md`'s reproducible two-device demonstration](../README.md#reproducible-two-device-demonstration), substituting your deployed HTTPS origin for `http://10.0.2.2:8080`.

## 3. Known v1 deployment limits

- There is no CI/CD pipeline that builds and pushes the Docker image automatically; `docker compose ... up -d --build` on the VPS builds it in place. This is adequate for v1's single-instance deployment and avoids adding a container registry dependency.
- There is no zero-downtime deploy step; `docker compose up -d --build api` briefly stops and restarts the API container. Given v1's single-account, foreground-first sync design, a client mid-sync simply retries per the documented backoff behavior.
- TLS certificate renewal (Let's Encrypt via Caddy or certbot) must be confirmed to auto-renew; both tools do this by default, but verify it on your specific VPS distribution.
