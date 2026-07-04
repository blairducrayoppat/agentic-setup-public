# nginx and reverse proxies — coder reference

This covers writing and validating nginx configuration files, with a focus on the reverse-proxy role: `server`/`location` routing, `proxy_pass`, `upstream` load-balancing pools, forwarding the right headers, terminating TLS, and proxying WebSockets. The primary tool is the `nginx` binary itself — especially `nginx -t` to **test config before** anything goes live and `nginx -s reload` to apply it. Config lives in `nginx.conf` plus files it `include`s (commonly `conf.d/*.conf` or `sites-enabled/*`).

## Key tools / cmdlets / APIs

- `nginx -t` — test/validate the config syntax and exit (does **not** apply it). The validation gate; run this before every reload.
- `nginx -T` — test config **and** dump the full effective config (all includes resolved) to stdout. Great for "show me what nginx will actually use".
- `nginx -s reload` — gracefully reload config (re-reads files, starts new workers, drains old ones). No dropped connections; preferred over restart.
- `nginx -s quit` — graceful shutdown (finish in-flight requests). `nginx -s stop` = fast shutdown.
- `nginx -c /path/nginx.conf` — run with an explicit config path (useful for testing an alternate file).
- `nginx -v` / `nginx -V` — version; `-V` also prints compile-time flags and configured modules.
- `proxy_pass URL;` — the core reverse-proxy directive: forward the request to a backend (`http://...`, `https://...`, or an `upstream` name).
- `upstream NAME { ... }` — define a named pool of backend `server` entries (enables load balancing, health/failover params, keepalive).
- `location MATCH { ... }` — route requests by URI to a block of directives.
- `proxy_set_header NAME VALUE;` — set/override a header sent to the backend (Host, X-Forwarded-*, Upgrade, etc.).
- `listen`, `server_name`, `ssl_certificate` / `ssl_certificate_key` — bind a port, select a virtual host by hostname, and enable TLS.
- `return CODE [URL];` and `rewrite REGEX REPLACEMENT [flag];` — redirects/URL rewriting (prefer `return` for simple redirects).
- Log streams to read first: `error_log` (default `logs/error.log`) and `access_log` (default `logs/access.log`).

## Common task patterns

**Read/inspect first — before changing anything, see what is actually loaded:**

```sh
# Validate syntax, then dump the FULL effective config (all includes merged).
nginx -t
nginx -T | less

# Find where the running config and its includes live, and the version/modules.
nginx -V 2>&1 | tr ' ' '\n' | grep -- --conf-path
nginx -V
```

**1. Minimal reverse proxy to one backend (with the standard forwarded headers):**

```nginx
server {
    listen 80;
    server_name app.example.com;

    location / {
        proxy_pass http://127.0.0.1:3000;

        # Preserve the client's original request info for the backend.
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host  $host;
    }
}
```

**2. Load-balanced upstream pool (with keepalive to backends):**

```nginx
upstream app_backend {
    # Default algorithm is round-robin. Alternatives: least_conn; ip_hash;
    least_conn;

    server 10.0.0.11:3000 max_fails=3 fail_timeout=30s;
    server 10.0.0.12:3000 max_fails=3 fail_timeout=30s;
    server 10.0.0.13:3000 backup;            # only used if the others are down

    keepalive 32;                            # reuse connections to backends
}

server {
    listen 80;
    server_name app.example.com;

    location / {
        proxy_pass http://app_backend;       # references the upstream by name

        # Required for upstream keepalive to actually work:
        proxy_http_version 1.1;
        proxy_set_header   Connection "";

        proxy_set_header Host              $host;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

**3. WebSocket-aware proxy (the `Upgrade`/`Connection` map is the canonical pattern):**

```nginx
# Put this in the http{} context (e.g. top of nginx.conf or a conf.d file).
# It sets Connection: upgrade only when the client requested a WS upgrade,
# otherwise Connection: close — so normal HTTP keepalive isn't broken.
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    server_name ws.example.com;

    location / {
        proxy_pass http://127.0.0.1:8080;

        proxy_http_version 1.1;                      # WebSockets require HTTP/1.1
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host       $host;

        proxy_read_timeout 3600s;                    # keep long-lived sockets open
    }
}
```

**4. TLS termination + HTTP→HTTPS redirect (clean, full example):**

```nginx
# Plain HTTP: redirect everything to HTTPS.
server {
    listen 80;
    server_name app.example.com;
    return 301 https://$host$request_uri;
}

# HTTPS: terminate TLS here, proxy plaintext to the backend.
server {
    listen 443 ssl;
    http2 on;                                   # nginx >= 1.25.1 syntax; older: "listen 443 ssl http2;"
    server_name app.example.com;

    ssl_certificate     /etc/nginx/certs/app.example.com.fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/app.example.com.key;

    # Sane, broadly-compatible TLS baseline (verify against current docs for your nginx/OpenSSL).
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;   # backend sees "https"
    }
}
```

**5. Path-based routing to multiple services (API vs. app vs. static):**

```nginx
server {
    listen 80;
    server_name example.com;

    # Exact match wins over prefix matches.
    location = /healthz {
        return 200 "ok\n";
        add_header Content-Type text/plain;
    }

    # Prefix match: send /api/... to the API service.
    location /api/ {
        proxy_pass http://127.0.0.1:9000;     # NOTE: trailing-slash behavior below
        proxy_set_header Host            $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    # Everything else to the web app.
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host            $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
```

**6. Reusable proxy header snippet (DRY — `include` it in each location):**

```nginx
# File: /etc/nginx/snippets/proxy-headers.conf
proxy_set_header Host              $host;
proxy_set_header X-Real-IP         $remote_addr;
proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_http_version 1.1;
```

```nginx
# In a server/location block:
location / {
    proxy_pass http://app_backend;
    include /etc/nginx/snippets/proxy-headers.conf;
}
```

**7. Serve static files with a proxied fallback (try local, else backend):**

```nginx
location / {
    root /var/www/site;
    try_files $uri $uri/ @backend;
}

location @backend {
    proxy_pass http://127.0.0.1:3000;
    proxy_set_header Host            $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
}
```

## Pitfalls

- **The trailing slash on `proxy_pass` changes URI rewriting.** With a URI part present, `proxy_pass http://host/;` (trailing slash) **strips** the `location` prefix; `proxy_pass http://host;` (no path) **passes the full URI** through. Example: for `location /api/`, `proxy_pass http://backend/;` turns `/api/users` into `/users`, while `proxy_pass http://backend;` keeps `/api/users`. Pick deliberately and test. (Variables/regex in the target follow different rules — verify against current docs.)
- **Forgetting `proxy_set_header Host $host;`.** Without it nginx sends the **upstream's** host (e.g. `127.0.0.1:3000`) as `Host`, which breaks name-based vhosts, redirects, and cookies on the backend.
- **WebSockets silently fail without HTTP/1.1 + the Upgrade/Connection headers.** A plain `proxy_pass` defaults to HTTP/1.0 and drops the `Upgrade` header — the handshake 400s or hangs. You need `proxy_http_version 1.1;` plus the `map $http_upgrade $connection_upgrade` pattern (#3).
- **Upstream keepalive needs `proxy_http_version 1.1;` AND `proxy_set_header Connection "";`.** Just adding `keepalive N;` to the `upstream` block does nothing if the proxied requests still send `Connection: close`.
- **Editing config does not apply it.** Changes only take effect after a successful `nginx -t` **and** a `nginx -s reload` (or restart). And `nginx -t` validates syntax/structure — it does **not** prove the backend is reachable or that TLS cert paths point at valid files.
- **`location` matching order is not top-to-bottom.** nginx picks exact (`=`) first, then the longest matching prefix, then regex (`~` / `~*`) in file order. Assuming "first block wins" leads to the wrong route.

## Security — OPERATOR REVIEW REQUIRED

The coding agent's job is to **write** nginx config files and helper scripts. It must **never auto-execute** an operation that swaps a live config or restarts/reloads a production nginx. Validation (`nginx -t` / `nginx -T`) is read-only and safe to run; **applying** a config is not. The operations below are destructive/disruptive — emit them as scripts for a human to run **deliberately**, each flagged below.

**Safe to run automatically (read-only / non-disruptive):**

```sh
nginx -t                # validate syntax of the active config (no apply)
nginx -t -c ./candidate.conf   # validate a candidate file without installing it
nginx -T                # validate + print the full effective config
```

**OPERATOR REVIEW REQUIRED — do not auto-run** — *replacing a live nginx config.* Always validate the candidate first, back up the current file, then swap. The dry-run equivalent is `nginx -t` on the candidate (it is the only "what-if" nginx offers for config content):

```sh
#!/bin/sh
# OPERATOR REVIEW REQUIRED — do not auto-run.
set -eu
CANDIDATE="$1"                      # e.g. ./app.example.com.conf
TARGET="/etc/nginx/conf.d/app.example.com.conf"

# 1. DRY-RUN: prove the candidate is valid BEFORE touching anything live.
nginx -t -c "$CANDIDATE"   # if your candidate is a server/location snippet, validate
                           # via a temp full config that `include`s it instead.

# 2. Back up the current live file (timestamped) so the swap is reversible.
cp -p "$TARGET" "${TARGET}.bak.$(date +%Y%m%d-%H%M%S)"

# 3. Install the new file.
cp -p "$CANDIDATE" "$TARGET"

# 4. Re-validate the WHOLE config now that the new file is in place.
nginx -t
echo "Config installed and validated. Reload is a SEPARATE, deliberate step (below)."
```

**OPERATOR REVIEW REQUIRED — do not auto-run** — *reloading nginx in production.* Reload only after `nginx -t` passes. `nginx -s reload` is graceful (no dropped connections); a full `restart` is **not** and should be rarer:

```sh
#!/bin/sh
# OPERATOR REVIEW REQUIRED — do not auto-run.
set -eu

# DRY-RUN gate: never reload a config that fails validation.
nginx -t

# Graceful reload (preferred): re-reads config, spins up new workers, drains old.
nginx -s reload

# If a hard restart is truly required, the operator runs it deliberately, e.g.:
#   systemctl restart nginx        # systemd hosts  (NOT graceful)
#   nginx -s quit && nginx         # manual graceful stop, then start
```

**Rollback (operator-run, after a bad reload):**

```sh
#!/bin/sh
# OPERATOR REVIEW REQUIRED — do not auto-run.
set -eu
TARGET="/etc/nginx/conf.d/app.example.com.conf"
LATEST_BAK="$(ls -1t "${TARGET}".bak.* | head -n1)"

cp -p "$LATEST_BAK" "$TARGET"
nginx -t && nginx -s reload     # validate the restored file, then graceful reload
```

**Other operator-review-required items in this domain:** writing private TLS key files (`ssl_certificate_key`) — set restrictive permissions and never commit keys to a repo; opening firewall ports for `listen`; and any `systemctl enable/start/stop nginx`. Exact service-management commands vary by platform — **verify against your host's init system and current nginx docs.**
