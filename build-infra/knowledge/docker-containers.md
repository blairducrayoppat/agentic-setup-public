# Docker and containers — coder reference

This covers writing `Dockerfile`s and `docker-compose.yml` (Compose v2) for application images, plus the validation steps to prove them before anyone runs them. The primary CLI is `docker` (with the bundled `docker compose` subcommand — note the **space**, not the old `docker-compose` hyphenated binary); the primary linter is `hadolint`. This agent WRITES these files; it does not run destructive Docker operations (see Security).

## Key tools / cmdlets / APIs
- `docker build -t name:tag .` — build an image from a `Dockerfile` in the build context `.`.
- `docker build --target stage -t name:tag .` — build only up to a named multi-stage stage.
- `docker compose config` — parse + validate `docker-compose.yml`, print the fully-resolved config (read-only; nothing runs).
- `docker compose up -d` / `docker compose down` — start / stop the stack (down WITHOUT `-v` keeps named volumes).
- `docker compose build` — build the images declared by the compose file.
- `hadolint Dockerfile` — lint a Dockerfile against best-practice rules (DL****/SC**** codes).
- `docker run --rm name:tag` — run a one-off container that deletes itself on exit (good for smoke tests).
- `docker image ls` / `docker ps` — read-only listing of images / running containers (query before you change anything).
- `docker scout cves name:tag` — report known CVEs in an image (read-only; may need network/login — verify against current docs if offline).
- `.dockerignore` — file (next to the Dockerfile) listing paths excluded from the build context, like `.gitignore`.

## Common task patterns
Read/query first: inspect what exists before building or changing it.

**1. Inspect before you act (read-only).**
```bash
docker image ls                 # what images already exist + their sizes
docker ps -a                    # running + stopped containers
docker compose config           # validate + show resolved compose config, runs nothing
docker history name:tag         # layer-by-layer breakdown (find the fat layers)
```

**2. Multi-stage Dockerfile (build stage + slim non-root runtime).** This is the canonical shape: a fat build stage compiles/installs, then only the artifacts are copied into a small, pinned, non-root runtime. Example is Python; the pattern is identical for Go/Node/.NET (swap the base + build commands).
```dockerfile
# syntax=docker/dockerfile:1

# ---- build stage: has compilers/dev headers, never shipped ----
FROM python:3.12-slim AS build
WORKDIR /app
# Copy only dependency manifests first so this layer caches across code edits.
COPY requirements.txt .
# BuildKit cache mount keeps the pip cache between builds without bloating the image.
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --prefix=/install --no-cache-dir -r requirements.txt
COPY . .

# ---- runtime stage: small, pinned, non-root ----
FROM python:3.12-slim AS runtime
# Create an unprivileged user to run as (do NOT run as root).
RUN groupadd --system app && useradd --system --gid app --home /app app
WORKDIR /app
# Pull in only the installed deps + the app, not the toolchain.
COPY --from=build /install /usr/local
COPY --from=build --chown=app:app /app /app
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
USER app
EXPOSE 8000
# Exec-form CMD (JSON array) so signals reach the process directly.
CMD ["python", "-m", "app"]
```

**3. `.dockerignore` (cut context size + keep secrets/junk out of the image).** A smaller context means faster builds and fewer cache busts.
```gitignore
.git
.gitignore
**/__pycache__/
*.pyc
.venv/
node_modules/
dist/
build/
*.log
.env
.env.*
Dockerfile
docker-compose*.yml
.dockerignore
README.md
```

**4. `docker-compose.yml` (app + dependency, healthcheck, no public port).** Pins image tags, binds the app port to **localhost only** (`127.0.0.1:`) so it is not exposed on the LAN, and uses a named volume + healthcheck. Note: NO `version:` key — it is obsolete and ignored in Compose v2.
```yaml
services:
  app:
    build:
      context: .
      target: runtime          # build the runtime stage from the multi-stage Dockerfile
    image: myapp:0.1.0          # explicit tag, never rely on :latest
    restart: unless-stopped
    ports:
      - "127.0.0.1:8000:8000"  # host-loopback only; see Security before exposing publicly
    environment:
      DATABASE_URL: postgres://app:app@db:5432/app
    depends_on:
      db:
        condition: service_healthy
    read_only: true            # container root FS is read-only
    tmpfs:
      - /tmp                    # writable scratch that doesn't persist
    security_opt:
      - no-new-privileges:true

  db:
    image: postgres:16.4       # pinned minor, not postgres:latest
    restart: unless-stopped
    environment:
      POSTGRES_USER: app
      POSTGRES_PASSWORD: app   # demo only; use a secret/env-file in real use
      POSTGRES_DB: app
    volumes:
      - dbdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U app -d app"]
      interval: 10s
      timeout: 5s
      retries: 5

volumes:
  dbdata:                      # named volume; survives `docker compose down` (without -v)
```

**5. Validate everything (the non-destructive gate).** Run these before handing the files off — none of them start long-lived services or delete anything.
```bash
hadolint Dockerfile                      # lint the Dockerfile
docker compose config -q                 # validate compose YAML; -q = quiet, errors only
docker build -t myapp:0.1.0 .            # prove it actually builds
docker build --target build -t myapp:build .   # build just one stage to debug
```

**6. Pin a base image by digest (reproducible / supply-chain).** A tag like `3.12-slim` can move; a digest (`@sha256:...`) is immutable. Get the digest from a registry/`docker buildx imagetools inspect`, then:
```dockerfile
FROM python:3.12-slim@sha256:<digest-here> AS build
```
Verify the current digest against the registry — do not hand-write a sha you didn't look up.

**7. Smoke-test the built image (self-cleaning).** `--rm` deletes the container on exit, so this leaves nothing behind.
```bash
docker run --rm myapp:0.1.0 python -c "print('image runs')"
docker run --rm -p 127.0.0.1:8000:8000 myapp:0.1.0   # try it on loopback, Ctrl-C to stop
```

**8. Lint in CI / offline via the hadolint image (when the binary isn't installed).**
```bash
docker run --rm -i hadolint/hadolint < Dockerfile   # pipe the Dockerfile in on stdin
```

## Pitfalls
- **`:latest` and floating tags.** `FROM node:latest` / `image: redis` give you a different image over time — non-reproducible and a security drift risk. Always pin (`node:20.17-slim`, ideally a digest).
- **Layer-cache order.** Copying the whole source (`COPY . .`) before installing deps busts the dependency layer on every code edit, so installs re-run every build. Copy manifests (`requirements.txt`, `package.json`, `go.mod`) and install FIRST, then copy the rest.
- **Running as root.** Containers run as root by default. Without a `USER` line, a container escape runs as root. Create an unprivileged user in the runtime stage and `USER` to it.
- **Fat single-stage images.** Shipping the build toolchain (compilers, dev headers, `node_modules` devDeps) bloats the image and widens the attack surface. Use multi-stage and copy only artifacts into a `-slim`/`-alpine`/distroless runtime.
- **Shell-form `CMD`/`ENTRYPOINT`.** `CMD python app.py` (shell form) wraps the process in `/bin/sh -c`, so it doesn't get `SIGTERM` and won't shut down cleanly. Use exec form: `CMD ["python", "app.py"]`.
- **No `.dockerignore`.** The whole directory (`.git`, `.venv`, `node_modules`, secrets) ships into the build context — slow builds and potential secret leakage. Always add one.
- **`docker compose` vs `docker-compose`.** The hyphenated v1 binary is end-of-life. Use the `docker compose` (space) subcommand. Also: do NOT add a top-level `version:` key — it's obsolete in v2 and emits a warning.

## Security — OPERATOR REVIEW REQUIRED
This agent writes Dockerfiles/compose files and runs only the **read-only / build / lint** validation above. The operations below are DESTRUCTIVE or expose the host. The agent must NOT auto-run them — emit them as scripts the human runs deliberately, with a dry-run/`-WhatIf` form shown where one exists.

- **`docker system prune` — OPERATOR REVIEW REQUIRED — do not auto-run.** Deletes stopped containers, dangling images, unused networks, and the build cache; with `-a --volumes` it also removes ALL unused images and **named volumes (data loss)**. There is no `--dry-run` on `prune`; preview with read-only `df`/`ls` first.
  ```bash
  # PREVIEW (read-only, safe to run):
  docker system df -v          # what is using space
  docker image ls -f dangling=true   # exactly which images prune would remove
  # OPERATOR-ONLY, destructive — run manually after reviewing the preview:
  # docker system prune -a --volumes
  ```

- **Removing volumes / images — OPERATOR REVIEW REQUIRED — do not auto-run.** `docker volume rm` and `docker compose down -v` destroy persistent data permanently; `docker rmi -f` force-deletes images.
  ```bash
  # PREVIEW (read-only):
  docker volume ls
  docker compose config --volumes    # list the named volumes this stack defines
  # OPERATOR-ONLY, destructive — data loss:
  # docker compose down -v            # 'down' alone keeps volumes; '-v' wipes them
  # docker volume rm <name>
  # docker rmi -f <image>
  ```

- **Privileged / capability-granting containers — OPERATOR REVIEW REQUIRED — do not auto-run.** `--privileged`, `--cap-add`, `--pid=host`, `-v /var/run/docker.sock:...`, and mounting host paths can break container isolation and hand the container host-level control. The agent should NEVER put these in a generated Dockerfile/compose file by default. If a workload truly needs one, leave it commented with a `# OPERATOR REVIEW REQUIRED` note for the human to enable.
  ```yaml
  # OPERATOR REVIEW REQUIRED — do not enable without review (breaks isolation):
  #   privileged: true
  #   cap_add: ["SYS_ADMIN"]
  #   volumes: ["/var/run/docker.sock:/var/run/docker.sock"]   # = host root, effectively
  # Prefer the safe defaults instead:  no-new-privileges:true, read_only:true, drop caps.
  ```

- **Publishing ports publicly — OPERATOR REVIEW REQUIRED — do not auto-run.** `"8000:8000"` (or `"0.0.0.0:8000:8000"`) binds to ALL host interfaces — reachable from the LAN/internet, and Docker's published ports can bypass host firewalls (e.g. ufw) by writing iptables/NAT rules directly. Default to loopback: `"127.0.0.1:8000:8000"`. Widening the bind is an operator decision.
  ```yaml
  ports:
    - "127.0.0.1:8000:8000"        # SAFE default: host-only
  # OPERATOR REVIEW REQUIRED — exposes the service on every interface:
  #   - "8000:8000"
  ```

- **Secrets in images / env — review before shipping.** Never `COPY` a `.env`, key, or token into an image (it's baked into a layer and recoverable via `docker history`), and never hard-code credentials in a `Dockerfile`. Use Docker/Compose secrets or runtime env injection, and add `.env`/`*.key`/`*.pem` to `.dockerignore`. Treat any generated file containing a credential as OPERATOR REVIEW REQUIRED.

> Notes for the agent: `docker scout` / registry-digest lookups need network or a logged-in registry — when offline, **verify against current docs** rather than guessing tags or shas. Stick to the read-only/build/lint commands in *Common task patterns* for autonomous validation; route everything in this section to the human.
