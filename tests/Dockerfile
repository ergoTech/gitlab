# The image tests/run.sh runs every test in. Ubuntu 24.04 is the GitLab host's
# release, so bash, coreutils and curl behave here as they do there. curl and
# openssl are for tests/test-notify-backoffice.sh, which sends real requests to
# a local HTTPS stand-in for the intake (python3); nothing here is installed on
# the host itself.
FROM ubuntu:24.04
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl openssl python3 \
    && rm -rf /var/lib/apt/lists/*
