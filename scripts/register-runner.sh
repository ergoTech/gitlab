#!/bin/bash
# GitLab Runner Registration Script
# 
# This script registers a GitLab Runner with Docker executor
# Run this after GitLab is fully initialized (usually 3-5 minutes after docker compose up)

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Run from the repository root, so .env is found however the script is invoked
cd "$(dirname "$0")/.."

# Load environment variables. Sourcing rather than `export $(... | xargs)`: the
# latter drops EVERY variable on the first quote or inline comment in .env, and
# a bare `export` then succeeds while setting nothing - so the https branch
# below would silently register the http configuration.
if [ -f .env ]; then
    if ! bash -n ./.env 2>/dev/null; then
        echo -e "${RED}Error: .env cannot be parsed${NC}"
        echo "A value containing a quote or a space has to be quoted, e.g. PASS='don'\''t' or PASS=\"a b\"."
        echo "Refusing to continue: an unreadable .env would look like an empty one and register the wrong runner."
        exit 1
    fi
    set -a
    . ./.env
    set +a
fi

# Default values
GITLAB_URL="http://${GITLAB_HOSTNAME:-gitlab.local}"
RUNNER_NAME="${RUNNER_DESCRIPTION:-docker-runner}"
RUNNER_TAGS="${RUNNER_TAGS:-docker,linux,arm64}"

# Same knob as GITLAB_EXTERNAL_SCHEME in .env.sample, normalised and checked
# here because the whole registration shape hangs off it.
EXTERNAL_SCHEME=$(echo "${GITLAB_EXTERNAL_SCHEME:-http}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
if [ "$EXTERNAL_SCHEME" != "http" ] && [ "$EXTERNAL_SCHEME" != "https" ]; then
    echo -e "${RED}Error: GITLAB_EXTERNAL_SCHEME must be http or https, got '${GITLAB_EXTERNAL_SCHEME}'${NC}"
    exit 1
fi
if [ "$EXTERNAL_SCHEME" = "https" ] && [ -z "${GITLAB_HOSTNAME}" ]; then
    echo -e "${RED}Error: GITLAB_EXTERNAL_SCHEME=https needs GITLAB_HOSTNAME set${NC}"
    echo "The runner clones from https://\$GITLAB_HOSTNAME; empty means every job fails at checkout."
    exit 1
fi

echo -e "${YELLOW}=== GitLab Runner Registration ===${NC}"
echo ""

# Check if GitLab is running
echo -e "${YELLOW}Checking if GitLab is running...${NC}"
if ! docker ps | grep -q "gitlab"; then
    echo -e "${RED}Error: GitLab container is not running!${NC}"
    echo "Run 'docker compose up -d' first and wait for GitLab to initialize."
    exit 1
fi

# Check GitLab health
echo -e "${YELLOW}Checking GitLab health...${NC}"
HEALTH_STATUS=$(docker inspect --format='{{.State.Health.Status}}' gitlab 2>/dev/null || echo "unknown")
if [ "$HEALTH_STATUS" != "healthy" ]; then
    echo -e "${YELLOW}Warning: GitLab is not fully healthy yet (status: $HEALTH_STATUS)${NC}"
    echo "GitLab may still be initializing. This can take 3-5 minutes."
    echo ""
    read -p "Do you want to continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Get authentication token
echo ""
echo -e "${YELLOW}=== GitLab 16.0+ New Runner Registration Workflow ===${NC}"
echo ""
echo -e "${YELLOW}IMPORTANT: You must create the runner in GitLab UI first!${NC}"
echo ""
echo "Follow these steps:"
echo ""
# Determine the correct URL based on setup
if [[ "${GITLAB_HOSTNAME}" == *"."* ]] && [[ -z "${GITLAB_HTTP_PORT}" || "${GITLAB_HTTP_PORT}" == "80" || "${GITLAB_HTTP_PORT}" == "443" ]]; then
    # Production setup with domain (Cloudflare/Nginx)
    echo "  1. Go to https://${GITLAB_HOSTNAME}"
else
    # Local development setup
    echo "  1. Go to http://${GITLAB_HOSTNAME:-gitlab.local}:${GITLAB_HTTP_PORT:-8080}"
fi
echo "  2. Login as root (password from .env or run ./scripts/get-root-password.sh)"
echo "  3. Go to Admin Area → CI/CD → Runners"
echo "  4. Click 'New instance runner'"
echo "  5. Configure runner settings:"
echo "     - Platform: Linux"
echo "     - Tags: docker, linux, arm64 (or any tags you want)"
echo "     - Run untagged jobs: ✓ Enable (recommended for testing)"
echo "     - Protected: Leave unchecked (unless needed)"
echo "  6. Click 'Create runner'"
echo "  7. Copy the authentication token (starts with 'glrt-')"
echo ""
echo -e "${YELLOW}Note: All runner settings (tags, description, etc.) are configured in the UI.${NC}"
echo -e "${YELLOW}This script only registers the runner with the token you provide.${NC}"
echo ""

if [ -n "$GITLAB_RUNNER_REGISTRATION_TOKEN" ]; then
    echo -e "${GREEN}Found token in .env file: GITLAB_RUNNER_REGISTRATION_TOKEN${NC}"
    TOKEN="$GITLAB_RUNNER_REGISTRATION_TOKEN"
else
    read -p "Enter authentication token (glrt-...): " TOKEN
fi

if [ -z "$TOKEN" ]; then
    echo -e "${RED}Error: No token provided!${NC}"
    exit 1
fi

# Validate token format
if [[ ! "$TOKEN" =~ ^glrt- ]]; then
    echo ""
    echo -e "${RED}WARNING: Token doesn't start with 'glrt-'${NC}"
    echo "Make sure you're using the NEW authentication token from 'New instance runner',"
    echo "not the old registration token (which is deprecated)."
    echo ""
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Register the runner
echo ""
echo -e "${YELLOW}Registering runner with GitLab...${NC}"
echo ""

# How job containers reach GitLab depends on whether a proxy in front terminates
# TLS.
#
# http (local): jobs join gitlab-network and clone external_url directly, so the
# public name has to resolve to the gitlab container. --docker-network-mode is
# what puts them there.
#
# https (proxy in front): the clone URL is public, so jobs have no reason to sit
# on gitlab-network - give each job its own network instead. The explicit
# --clone-url is the load-bearing half: with it left out the job clones whatever
# GitLab advertises, and a proxy that redirects http -> https makes git drop the
# Authorization header on the redirect. The job token is then gone by the time
# GitLab sees the request, and the clone dies with "HTTP Basic: Access denied"
# and exit code 128, which reads like a broken token and is nothing of the sort.
if [ "$EXTERNAL_SCHEME" = "https" ]; then
    REGISTER_NETWORK_ARGS=(
        --env "FF_NETWORK_PER_BUILD=true"
        --clone-url "https://${GITLAB_HOSTNAME}"
    )
    NETWORK_SUMMARY="per-build (clone URL: https://${GITLAB_HOSTNAME})"
else
    REGISTER_NETWORK_ARGS=(--docker-network-mode "gitlab-network")
    NETWORK_SUMMARY="gitlab-network (clone URL: whatever GitLab advertises)"
fi
echo -e "${YELLOW}Job network:${NC} ${NETWORK_SUMMARY}"
echo ""

# Service containers inherit the docker DAEMON's soft nofile limit. The runner's
# own ulimit setting does not help: gitlab-runner applies it to the build
# container and not to services. A systemd default of 1024 is enough for mongod
# to start and not enough for it to survive - it exhausts descriptors mid-job,
# WiredTiger panics on a directory sync (EMFILE), the container exits 133, and
# the job sees only a database that stopped answering. So warn here and fix it
# on the daemon.
DAEMON_NOFILE=$(docker run --rm alpine:latest sh -c 'ulimit -Sn' 2>/dev/null || echo "")
if [ -z "$DAEMON_NOFILE" ]; then
    echo -e "${YELLOW}Warning: could not determine the daemon's nofile limit.${NC}"
    echo "Check it by hand - this is the only thing standing between a database"
    echo "service container and a mid-job crash. See default-ulimits in daemon.json."
    echo ""
elif [ "$DAEMON_NOFILE" != "unlimited" ] && [ "$DAEMON_NOFILE" -lt 64000 ] 2>/dev/null; then
    echo -e "${YELLOW}Warning: containers start with a soft nofile limit of ${DAEMON_NOFILE}.${NC}"
    echo "Database service containers (mongo, postgres) need roughly 64000 and will"
    echo "die mid-job without it. Add this to /etc/docker/daemon.json and restart docker:"
    echo '  "default-ulimits": { "nofile": { "Name": "nofile", "Soft": 64000, "Hard": 524288 } }'
    echo ""
fi

docker exec gitlab-runner gitlab-runner register \
    --non-interactive \
    --url "http://gitlab" \
    --token "$TOKEN" \
    --executor "docker" \
    --docker-image "alpine:latest" \
    --docker-privileged \
    --docker-volumes "/var/run/docker.sock:/var/run/docker.sock" \
    --docker-volumes "/cache" \
    "${REGISTER_NETWORK_ARGS[@]}"

if [ $? -eq 0 ]; then
    echo ""
    echo -e "${YELLOW}Fixing helper_image for arm64 compatibility...${NC}"

    # Insert helper_image line before network_mtu (it doesn't exist by default)
    # This adds: helper_image = "gitlab/gitlab-runner-helper:arm64-bleeding"
    docker exec gitlab-runner sed -i '/network_mtu = 0/i\    helper_image = "gitlab/gitlab-runner-helper:arm64-bleeding"' /etc/gitlab-runner/config.toml

    # Also disable cache to avoid permission issues with helper image
    docker exec gitlab-runner sed -i 's/disable_cache = false/disable_cache = true/' /etc/gitlab-runner/config.toml

    # Restart runner to apply changes
    echo -e "${YELLOW}Restarting runner to apply changes...${NC}"
    docker restart gitlab-runner > /dev/null 2>&1
    sleep 2

    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ✓ Runner registered successfully!                            ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "The runner is now active and ready to pick up jobs."
    echo ""
    echo -e "${YELLOW}Configuration Summary:${NC}"
    echo "  • Executor: Docker (with socket mounting)"
    echo "  • Default image: alpine:latest"
    echo "  • Privileged mode: Enabled"
    echo "  • Job network: ${NETWORK_SUMMARY}"
    echo "  • Docker socket: Mounted from host"
    echo ""
    echo -e "${YELLOW}View runner status:${NC}"
    echo "  • GitLab UI: Admin Area → CI/CD → Runners"
    echo "  • Command: docker exec gitlab-runner gitlab-runner list"
    echo ""
    echo -e "${YELLOW}Using the runner in .gitlab-ci.yml:${NC}"
    echo "  Use the tags you configured in the GitLab UI, for example:"
    echo ""
    echo "  build:"
    echo "    image: docker:latest"
    echo "    tags:"
    echo "      - docker"
    echo "    script:"
    echo "      - docker build -t my-image ."
    echo ""
    echo -e "${GREEN}All runner settings are managed in GitLab UI (tags, description, etc.)${NC}"
else
    echo ""
    echo -e "${RED}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  ✗ Runner registration failed!                                ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Check the error message above for details."
    echo ""
    echo -e "${YELLOW}Common issues:${NC}"
    echo "  • Invalid token (make sure it starts with 'glrt-')"
    echo "  • GitLab not fully initialized (wait 3-5 minutes after startup)"
    echo "  • Network connectivity issues"
    echo ""
    exit 1
fi

