# GitLab CE Docker Compose Setup

Full-featured self-hosted GitLab with Container Registry, Package Registry (npm, PyPI, Maven, etc.), and GitLab Runners.

**ARM64 Compatible** - Works on Apple Silicon (M1/M2/M3), Raspberry Pi, and other ARM64 platforms.

## Features

- ✅ **GitLab CE** - Full GitLab Community Edition
- ✅ **Container Registry** - Store and manage Docker images
- ✅ **Package Registry** - npm, PyPI, Maven, NuGet, Composer, etc.
- ✅ **GitLab Runner** - CI/CD with Docker executor (socket mounting)
- ✅ **Docker Support** - Build Docker images in pipelines using host Docker
- ✅ **Host Volumes** - Easy backup and migration
- ✅ **ARM64 Support** - Native support for Apple Silicon and ARM devices

## Prerequisites

- Docker Engine 20.10+ or Docker Desktop
- Docker Compose v2.0+
- At least 4GB RAM (8GB recommended)
- 10GB+ free disk space

## Quick Start

### 1. Clone and Configure

```bash
# Copy environment template
cp .env.sample .env

# Edit configuration
nano .env
```

**Important settings in `.env`:**
- `GITLAB_HOSTNAME` - Your GitLab hostname (e.g., `gitlab.local`)
- `GITLAB_EXTERNAL_SCHEME` - `http` (default) or `https` when a proxy in front
  terminates TLS. Changes behaviour, not just links: with `https`, the session
  cookie becomes `Secure` and plain-http login stops working. See `.env.sample`.
- `GITLAB_CONTAINER_HOSTNAME` - the container's hostname, which Docker also
  publishes to the whole network. Leave it unset on http (it defaults to
  `GITLAB_HOSTNAME`, which is what local CI clones rely on); set it to `gitlab`
  when `GITLAB_EXTERNAL_SCHEME=https`. See `.env.sample`.
- `GITLAB_ROOT_PASSWORD` - Initial root password (min 8 chars)
- `GITLAB_SSH_PORT` - SSH port for git operations (default: 2222)
- `GITLAB_HTTP_PORT` - HTTP port for web UI (default: 8080)
- `GITLAB_REGISTRY_PORT` - Container registry port (default: 5050)

### 2. Add Hostname to /etc/hosts

```bash
# Add this line to /etc/hosts
127.0.0.1 gitlab.local
```

Or use your actual hostname if deploying on a server.

### 3. Start GitLab

```bash
docker compose up -d
```

**First startup takes 3-5 minutes** while GitLab initializes.

Check status:
```bash
docker compose logs -f gitlab
```

Wait for: `gitlab Reconfigured!` message.

### 4. Access GitLab

Open: `http://gitlab.local:8080` (or your configured hostname/port)

**Login:**
- Username: `root`
- Password: From `.env` file (`GITLAB_ROOT_PASSWORD`)

### 5. Register GitLab Runner

**IMPORTANT: GitLab 16.0+ requires creating the runner in UI first!**

**Step 1: Create runner in GitLab UI**
1. Go to **Admin Area** → **CI/CD** → **Runners**
2. Click **New instance runner**
3. Select **Linux** platform
4. Configure settings:
   - **Tags**: `docker`, `linux`, `arm64` (or any tags you want)
   - **Run untagged jobs**: ✓ Enable (recommended)
5. Click **Create runner**
6. Copy the authentication token (starts with `glrt-`)

**Step 2: Register runner with token**
```bash
./scripts/register-runner.sh
```
Paste the token when prompted.

**Runner Configuration:**
- **Executor**: Docker with socket mounting
- **Default image**: `alpine:latest`
- **Docker access**: Via host Docker socket (`/var/run/docker.sock`)
- **Job network**: `gitlab-network` with `GITLAB_EXTERNAL_SCHEME=http`; one
  network per job plus an explicit clone URL with `https` (the script prints
  which one it picked)
- **Privileged mode**: Enabled (required for Docker operations)

**Note:** All runner settings (tags, description, etc.) are configured in GitLab UI before registration. This is the new workflow in GitLab 16.0+.

The runner communicates with GitLab via internal Docker network (`http://gitlab`), regardless of your external setup.

### 6. Configure Email (Optional)

GitLab is configured to use **MailerSend** for sending emails (notifications, password resets, etc.).

#### Setup MailerSend:

1. **Create MailerSend account**: https://app.mailersend.com/

2. **Add and verify your domain**:
   - Go to **Domains** → **Add Domain**
   - Add DNS records (SPF, DKIM, CNAME)
   - Wait for verification

3. **Get SMTP credentials**:
   - Go to **Domains** → Your domain → **SMTP**
   - Copy **Username** and **Password**

4. **Update `.env` file**:
   ```bash
   SMTP_USERNAME=your-mailersend-username
   SMTP_PASSWORD=your-mailersend-password
   GITLAB_EMAIL_FROM=gitlab@yourdomain.com
   GITLAB_EMAIL_REPLY_TO=noreply@yourdomain.com
   ```

5. **Restart GitLab**:
   ```bash
   docker compose down
   docker compose up -d
   ```

6. **Test email** (optional):
   ```bash
   docker exec -it gitlab gitlab-rails console

   # In Rails console:
   Notify.test_email('test@example.com', 'Test Subject', 'Test Body').deliver_now
   ```

**Note**: Email address in `GITLAB_EMAIL_FROM` must be verified in MailerSend.

## Usage

### Container Registry

#### Push Docker Image

```bash
# Login to registry
docker login gitlab.local:5050
# Username: your-gitlab-username
# Password: your-gitlab-password or access token

# Tag your image
docker tag my-image:latest gitlab.local:5050/group/project/my-image:latest

# Push
docker push gitlab.local:5050/group/project/my-image:latest
```

#### Pull Docker Image

```bash
docker pull gitlab.local:5050/group/project/my-image:latest
```

### Package Registry (npm)

#### Publish npm Package

```bash
# Create .npmrc in your project
echo "@scope:registry=http://gitlab.local:8080/api/v4/projects/PROJECT_ID/packages/npm/" > .npmrc
echo "//gitlab.local:8080/api/v4/projects/PROJECT_ID/packages/npm/:_authToken=YOUR_TOKEN" >> .npmrc

# Publish
npm publish
```

#### Install npm Package

```bash
# Add to .npmrc
echo "@scope:registry=http://gitlab.local:8080/api/v4/packages/npm/" >> .npmrc

# Install
npm install @scope/package-name
```

### CI/CD Pipeline Example

Create `.gitlab-ci.yml`:

```yaml
stages:
  - build
  - test

build-job:
  stage: build
  tags:
    - docker
    - linux
    - arm64
  script:
    - echo "Building..."
    - docker build -t my-app .
  
test-job:
  stage: test
  tags:
    - docker
  script:
    - echo "Testing..."
    - npm test
```

## Management

### View Logs

```bash
# All services
docker compose logs -f

# GitLab only
docker compose logs -f gitlab

# Runner only
docker compose logs -f gitlab-runner
```

### Restart Services

```bash
docker compose restart
```

### Stop Services

```bash
docker compose down
```

### Backup

```bash
# Backup all data
tar -czf gitlab-backup-$(date +%Y%m%d).tar.gz data/
```

### Restore

```bash
# Stop services
docker compose down

# Restore data
tar -xzf gitlab-backup-YYYYMMDD.tar.gz

# Start services
docker compose up -d
```

### Disk maintenance

Two things fill this host's disk and neither cleans up after itself:

- **The container registry.** Every pipeline pushes the same `:latest` tag, which
  leaves the previous manifest untagged. Untagged manifests and their blobs are
  never removed unless garbage collection runs with `-m`. Left alone this reached
  41 GB here. Master builds also push a `:<short-sha>` tag, and a tagged image
  is never collected at all: by 2026-10-08 the registry stood at 94 GB of a
  145 GB disk.
- **The runner's Docker state.** Multiarch builds leave buildkit cache and an
  unreferenced image per pipeline — 14.85 GB of cache and 56.56 GB of images
  (507 images, 26 of them in use).

`/var/run/docker.sock` is mounted into the runner, so every cleanup here
operates on whatever else shares that daemon. On the original host that was the
production stack itself, which is where this caution comes from; the GitLab-only
host it runs on now has nothing but `gitlab` and `gitlab-runner`, and the caution
is kept anyway. The script therefore never touches named volumes (prod databases
where they exist, and the runner caches, live in them), removes containers in one
case only — a CI build container named `runner-*` that exited over
`BUILD_CONTAINER_RETENTION_HOURS` ago, together with its own anonymous volumes,
and only on a pass that finds no CI job running, while exited one-shots like
`prod-migrate` are kept for their logs — and only ever prunes images and build
cache behind an age filter, including when it escalates. The one exception to
the named-volume rule is the runner's own cache volumes, and only as the last step
of an escalation (below).

**GitLab's cleanup policies cannot remove multi-arch tags on this registry**, so the
weekly GC pass untags old sha tags itself (`scripts/registry-prune-tags.sh`). The registry runs
without its metadata database, and then GitLab ages a tag by the `created` field of
the image config. A multi-arch image is an OCI index with no config, so it has no
age, and a policy with `older_than` keeps it. backend/core's sha tags are all
multi-arch: with keep 10 / older than 14d enabled on every project, it still had 375
tags, and the cleanup worker re-queued itself on it about once a second with
`deleted_size: 0`. The policies do clean the single-arch tags of other projects;
what they leave behind there is, again, the multi-arch ones.

What the script untags: tags named exactly like a short sha (`^[0-9a-f]{8}$`) that
are neither among the `REGISTRY_TAG_KEEP_N` (10) newest in their repository nor
pushed within `REGISTRY_TAG_RETENTION_DAYS` (14). `latest`, `master`, version tags
and other named tags are never touched. It removes the tag's directory in storage,
which is what the registry's own untag does; the manifest stays, so an image another
tag points at is safe, and GC then collects what no tag references. See what it
would remove without changing anything:

```bash
make registry-tags
```

When the disk fills, the registry starts answering `500 Internal Server Error` to
`POST /v2/<image>/blobs/uploads/`. Pipelines then fail at the push step **with a
completely green build above it**, which reads like a broken build and is not one.
If you see that error, check `df -h /` first.

Install the scheduled cleanup:

```bash
make install-cron
```

**Re-run it after any update that touches `scripts/maintenance.sh` or the cron
entries.** The installed `/etc/cron.d/gitlab-maintenance` is a snapshot, not a
symlink: pulling a new script without re-installing leaves the old entries in
place, and the mismatch is silent — the nightly run keeps working but stops
being quiet, mailing root every morning about a success.

That writes `/etc/cron.d/gitlab-maintenance`:

| When | What |
|------|------|
| Mon–Sat 03:30 | abandoned CI build containers (only with no CI job running), build cache unused for a day, unused images first tagged or pulled over a day ago, archived journals |
| Sun 03:30 | the above plus old sha tags untagged and registry garbage collection |
| every 15 min | disk alert to Telegram and the backoffice (see below) |

Registry GC **stops** the registry for the duration, which is why it is weekly and
at night: a push landing in that window fails its pipeline (retry it), though it
cannot corrupt the storage. Tags are untagged inside that same window, with the
registry already stopped, so no push can rewrite one while it goes. An interrupted
GC (reboot, OOM) leaves the registry stopped — the same 500-on-push symptom as a
full disk — so the script checks afterwards and starts it back up, shouting in the
log if it cannot.

Above 85% usage a run escalates, one step at a time and only while still over the
line: first a 1-hour age filter instead of 24 hours for build cache and images;
then, on a night that is not Sunday, the registry pass (tag pruning and GC); then
the runner's cache volumes that no container uses — a cold cache for the next job of
each project, nothing worse, since no pipeline here keeps correctness in them. If
the disk is still over the line after all that, the run fails with "needs a human".

The image filter stays a filter rather than dropping to nothing: an image a
pipeline built seconds ago has no container referencing it until it is
pushed, and sweeping it mid-pipeline would cause exactly the failure this script
exists to prevent.

That filter, not a check for running jobs, is what protects a live pipeline, so
build cache and images are pruned — and a run escalates — while a CI job is
running too. Skipping them whenever a job was running is how this disk reached
100% on 2026-09-11: a job was running at 03:30 on four of the ten nights up to
it, and on the last, at 93%, the run declined to escalate. Only abandoned CI build
containers still wait for a pass with no job running.

The filter does not cover everything, and each gap can fail the one job it hits
(retry it): a **reused** tag — `docker build -t X:latest` over an existing
`X:latest` keeps the tag's first creation time, so a prune between that build and
`docker push X:latest` can remove it; a build with `SOURCE_DATE_EPOCH` set, whose
tag is dated by that epoch rather than by the build; and a pull that is in flight
when the prune starts. The comment at `prune_images_and_build_cache` in the script
has the details.

Note on the age filter: it is not the CREATED column of `docker images`. On this
host's containerd image store an image's age is the time its **name** was created
here — by the build that first tagged it or the pull that first fetched it — and
build cache ages from its last **use**. The window is not "keep what we still
need" — it only keeps a just-built tag alive long enough to be pushed.

Run it by hand at any time:

```bash
make maintenance    # everything, including tag pruning and registry GC
make registry-gc    # the same as make maintenance
```

Log: `/var/log/gitlab-maintenance.log` (self-trimming at 10 MB). Registry GC's
per-blob lines are filtered out of it; its stage summaries stay.

A run prints its progress to stdout and appends it to the log. The cron entries
redirect stdout to `/dev/null`, so a scheduled run is silent unless it fails —
failures go to stderr and the exit code is non-zero, which is what makes cron
mail (`MAILTO`, default `root`) mean something actually broke. **The GitLab host
has no MTA, so that mail goes nowhere**; a run with failures also posts them to
Telegram and opens an alert in the backoffice, which the next clean run resolves
while the registry is up (see [Disk alert](#disk-alert)).

Tune via environment variables: `IMAGE_RETENTION` (default `24h`),
`ESCALATION_RETENTION` (`1h`), `BUILD_CONTAINER_RETENTION_HOURS` (`8`, a bare
number of hours — not a docker duration string), `DISK_ESCALATE_PCT` (`85`),
`MAINTENANCE_LOG`, `MAINTENANCE_LOCK`, `GITLAB_CONTAINER`, `REGISTRY_TAG_KEEP_N`
(`10`), `REGISTRY_TAG_RETENTION_DAYS` (`14`), `REGISTRY_REPOS` (registry storage
path). Set the cron recipient with `make install-cron MAINTENANCE_MAILTO=you@example.com`.

**Not covered by this script**, and worth doing separately: moving the registry to
its metadata database. GitLab's cleanup policies would then age tags from the
database and work for multi-arch images, and GC would run online instead of stopping
the registry. It is a migration with a read-only window, not a config switch. Job
artifacts also have no expiry here (748 MB on 2026-10-09).

### Disk alert

`scripts/disk-alert.sh` runs every 15 minutes and posts to the ops Telegram chat —
the same bot and chat as production's Alertmanager — when `/` reaches 85% (warning)
or 95% (critical), again every 6 hours while it stays at or above 85%, and once more
when it falls back below 80%. Both times this disk filled, the first sign was a failed
pipeline; this is meant to arrive days earlier.

The same alert also goes to the backoffice, through the backend's ops-alert intake
(`scripts/notify-backoffice.sh`), where it stays open until resolved: source
`gitlab-host`, key `disk-root`, fired with severity `warning` or `critical` and
resolved when the disk clears. A maintenance run with failures uses the same channel
with key `maintenance`, and the next run without failures resolves it — but only
with the registry up, since a weekday run never touches the registry and so cannot
vouch for a Sunday "registry left down".

Telegram is the channel that has to get through. The alert state only advances once
Telegram has taken the message, and a failed send is retried on the next run, to both
channels. The backoffice is tried first and never holds Telegram back; when it does
not take an alert, the Telegram message gets a line saying so — with cron mail going
nowhere, that line is where a wrong token shows up. A failure worth retrying (no
answer, 408, 429, 5xx) is retried on the next run, to the backoffice alone, and so is
an alert the backoffice took while Telegram failed; a refusal (a redirect, a wrong
token, any other 4xx) is not, since sending the same again cannot help. One gap: when
such a backoffice-only retry is refused, nothing reaches Telegram, and the backoffice
can be left showing a stale alert — resolve it there by hand.

Credentials are files under the gitignored `data/`, never in git. Telegram:

```bash
sudo install -d -m 700 data/alerts
# copy file to file from the host that runs Alertmanager — never paste the token
sudo chmod 600 data/alerts/bot_token data/alerts/chat_id
make disk-alert                                   # prints its decision, sends if due
sudo ./scripts/notify-telegram.sh "test message"  # proves delivery
```

The backoffice: `backoffice_url` holds the full intake URL, ending in
`/webhooks/ops-alerts`, and `backoffice_token` the backend's `OPS_ALERTS_TOKEN` (32
characters or more), copied file to file like the bot token:

```bash
echo 'https://<backend>/webhooks/ops-alerts' | sudo tee data/alerts/backoffice_url >/dev/null
# copy the backend's OPS_ALERTS_TOKEN into data/alerts/backoffice_token, file to file
sudo chmod 600 data/alerts/backoffice_url data/alerts/backoffice_token
sudo ./scripts/notify-backoffice.sh delivery-test firing info "Delivery test"; echo "exit $?"
sudo ./scripts/notify-backoffice.sh delivery-test resolved; echo "exit $?"
```

Both print nothing when they work, so read the exit code: `0` taken (the first opens
an alert in the backoffice, the second closes it), `3` the channel is off — no
`backoffice_url` where the script looks — and anything else comes with its reason.

Send that test from this host, not from a laptop: what has to work is the path from
here through whatever sits in front of the backend. Without `backoffice_url` the
channel is off and everything else works as before; without the Telegram files, the
message is not sent and the reason goes to stderr. Tune with `DISK_WARN_PCT` (85),
`DISK_CRIT_PCT` (95), `DISK_ALERT_CLEAR_PCT` (80), `DISK_ALERT_REPEAT_HOURS` (6),
`BACKOFFICE_TIMEOUT` (15 seconds) and `OPS_ALERT_SOURCE` (`gitlab-host`); state lives
in `/var/lib/gitlab-disk-alert/state`.

`make test` (needs Docker) runs the tests of these scripts in throwaway `ubuntu:24.04`
containers: docker, `df` and both senders are stubbed for the disk alert and the
maintenance run, and `notify-backoffice.sh` sends its real curl requests to a local
HTTPS stand-in for the intake.

## Troubleshooting

### GitLab not starting

Check logs:
```bash
docker compose logs gitlab
```

Common issues:
- Not enough memory (need 4GB+)
- Port conflicts (check ports 8080, 5050, 2222)
- Permissions on `data/` directory

### Runner not connecting

1. Check runner is registered:
```bash
docker exec gitlab-runner gitlab-runner list
```

2. Verify runner in GitLab UI: **Admin Area** → **CI/CD** → **Runners**

3. Re-register if needed:
```bash
./scripts/register-runner.sh
```

### Container Registry 404

Make sure you're using the correct URL format:
```
gitlab.local:5050/group/project/image:tag
```

### npm Registry 403 Forbidden

1. Check authentication token is valid
2. Verify project ID in `.npmrc`
3. Ensure package name matches scope: `@scope/package-name`

### Email not sending

1. **Check SMTP credentials** in `.env`:
   ```bash
   cat .env | grep SMTP
   ```

2. **Verify email configuration**:
   ```bash
   docker exec -it gitlab gitlab-rails console

   # Check SMTP settings:
   ActionMailer::Base.smtp_settings
   ```

3. **Test email delivery**:
   ```bash
   docker exec -it gitlab gitlab-rails console

   # Send test email:
   Notify.test_email('your-email@example.com', 'Test', 'Test message').deliver_now
   ```

4. **Check GitLab logs**:
   ```bash
   docker exec gitlab tail -f /var/log/gitlab/gitlab-rails/production.log
   ```

5. **Common issues**:
   - Email address not verified in MailerSend
   - Domain not verified (check SPF, DKIM, CNAME records)
   - Wrong SMTP credentials
   - Firewall blocking port 587
   - MailerSend rate limits exceeded

## Advanced Configuration

### External Nginx Proxy

If using external nginx for TLS, set both of these in `.env` first - the proxy
alone is not enough:

```bash
GITLAB_EXTERNAL_SCHEME=https      # or GitLab hands out http:// URLs
GITLAB_CONTAINER_HOSTNAME=gitlab  # or the public name resolves into the
                                  # container, on 443, where nothing listens
# The scheme knob does NOT reach the registry, so set this too, and give the
# registry its own name: the vhost below serves it on 443, which the main name
# is already using. Keeping it off a port also keeps it working behind a CDN
# that only proxies the standard ones.
GITLAB_REGISTRY_EXTERNAL_URL=https://registry.example.com
```

Then the vhost:

```nginx
server {
    listen 443 ssl;
    server_name gitlab.example.com;
    
    location / {
        proxy_pass http://localhost:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}

# Container Registry - its own name, so it can have 443 to itself.
# The upstream port is GITLAB_REGISTRY_PORT; change one and change the other.
server {
    listen 443 ssl;
    server_name registry.example.com;
    
    location / {
        proxy_pass http://localhost:5050;
        proxy_set_header Host $host;
    }
}
```

### Resource Limits

Uncomment in `.env`:
```bash
GITLAB_MEMORY_LIMIT=4g
GITLAB_CPU_LIMIT=2
```

## Ports

| Service | Port | Description |
|---------|------|-------------|
| GitLab Web | 8080 | Web interface |
| GitLab SSH | 2222 | Git over SSH |
| Container Registry | 5050 | Docker registry |

## Architecture

```
┌─────────────────┐
│  External Nginx │ (Optional, for TLS)
│   (Port 443)    │
└────────┬────────┘
         │
┌────────▼────────┐
│     GitLab      │
│  (Port 8080)    │
│                 │
│  - Web UI       │
│  - API          │
│  - Registry     │
│  - Packages     │
└────────┬────────┘
         │
┌────────▼────────┐
│  GitLab Runner  │
│                 │
│  - Docker exec  │
│  - CI/CD jobs   │
└────────┬────────┘
         │
┌────────▼────────┐
│  Docker-in-     │
│  Docker (dind)  │
│                 │
│  - Build images │
└─────────────────┘
```

## License

This setup uses GitLab Community Edition (CE) which is open source under the MIT License.

## Support

- [GitLab Documentation](https://docs.gitlab.com/)
- [GitLab Forum](https://forum.gitlab.com/)
- [Docker Documentation](https://docs.docker.com/)

