# GitLab Runner Setup Guide

This document explains the runner configuration used in this project and alternative approaches.

## Current Configuration: Socket Mounting

This project uses **Socket Mounting** approach for local development.

### How It Works

The GitLab Runner container mounts the host's Docker socket:

```yaml
gitlab-runner:
  volumes:
    - /var/run/docker.sock:/var/run/docker.sock
```

When a CI/CD job runs:
1. Runner creates a container for the job
2. Job container also has access to the Docker socket
3. Job can run Docker commands using the **host's Docker daemon**

### Advantages

✅ **Fast** - No overhead from Docker-in-Docker  
✅ **Simple** - Easy to set up and debug  
✅ **Efficient** - All jobs share the same Docker daemon  
✅ **Layer caching** - Docker build cache is shared across jobs  

### Disadvantages

⚠️ **Security** - Jobs have access to host Docker (can see/manipulate all containers)  
⚠️ **Isolation** - Jobs can interfere with each other  
⚠️ **Privileged** - Requires privileged mode  

### Best For

- Local development
- Trusted environments
- Single-user setups
- Fast iteration

## Alternative: Docker-in-Docker (DinD)

For production or multi-user environments, consider Docker-in-Docker.

### How It Works

Each job gets its own isolated Docker daemon:

```yaml
# .gitlab-ci.yml
build:
  image: docker:latest
  services:
    - docker:dind
  variables:
    DOCKER_HOST: tcp://docker:2375
    DOCKER_TLS_CERTDIR: ""
  script:
    - docker build -t my-image .
```

### Configuration Changes Needed

**1. Update docker-compose.yml:**
```yaml
gitlab-runner:
  volumes:
    - ${RUNNER_CONFIG_PATH:-./data/runner/config}:/etc/gitlab-runner
    # Remove: - /var/run/docker.sock:/var/run/docker.sock
```

**2. Update runner registration:**
```bash
docker exec gitlab-runner gitlab-runner register \
    --non-interactive \
    --url "http://gitlab" \
    --token "$TOKEN" \
    --executor "docker" \
    --docker-image "alpine:latest" \
    --docker-privileged \
    --docker-volumes "/cache" \
    --docker-network-mode "gitlab-network"
```

Behind a TLS-terminating proxy (`GITLAB_EXTERNAL_SCHEME=https`) drop
`--docker-network-mode` and register with these instead, or every job dies at
checkout on the proxy's http -> https redirect:

```bash
    --env "FF_NETWORK_PER_BUILD=true" \
    --clone-url "https://your.gitlab.host"
```

**3. Update .gitlab-ci.yml:**
```yaml
build:
  image: docker:latest
  services:
    - docker:dind
  variables:
    DOCKER_HOST: tcp://docker:2375
    DOCKER_TLS_CERTDIR: ""
  script:
    - docker build -t my-image .
```

### Advantages

✅ **Secure** - Jobs are isolated from host  
✅ **Safe** - Jobs can't see/affect other containers  
✅ **Production-ready** - Recommended for multi-user environments  

### Disadvantages

⚠️ **Slower** - Overhead from nested Docker  
⚠️ **Complex** - More moving parts  
⚠️ **No cache sharing** - Each job has fresh Docker daemon  

### Best For

- Production environments
- Multi-user/multi-tenant setups
- Untrusted code
- Security-critical applications

## GitLab 16.0+ Registration Workflow

GitLab changed runner registration in version 16.0:

### Old Way (Deprecated)
1. Get registration token from GitLab
2. Run `gitlab-runner register` with token
3. Configure tags, description via CLI

### New Way (Current)
1. **Create runner in GitLab UI first**
2. Configure all settings (tags, description, etc.) in UI
3. Get authentication token (starts with `glrt-`)
4. Run `gitlab-runner register` with authentication token

### Why the Change?

- Better security (tokens are scoped to specific runners)
- Centralized management (all settings in UI)
- Audit trail (who created what runner)
- Token rotation support

## Troubleshooting

### Runner not picking up jobs

1. Check runner is online:
   ```bash
   docker exec gitlab-runner gitlab-runner list
   ```

2. Verify tags match in `.gitlab-ci.yml`:
   ```yaml
   build:
     tags:
       - docker  # Must match runner tags
   ```

3. Check "Run untagged jobs" is enabled in GitLab UI

### Docker commands fail in jobs

**Socket Mounting:**
- Verify socket is mounted: `docker exec gitlab-runner ls -la /var/run/docker.sock`
- Check privileged mode is enabled

**Docker-in-Docker:**
- Verify `DOCKER_HOST` is set correctly
- Check `docker:dind` service is running
- Ensure network connectivity between job and dind

### Permission denied errors

- Runner needs privileged mode for Docker operations
- Check socket permissions: `ls -la /var/run/docker.sock` on host
- Verify runner user has Docker access

## References

- [GitLab Runner Executors](https://docs.gitlab.com/runner/executors/)
- [Docker Executor](https://docs.gitlab.com/runner/executors/docker.html)
- [New Runner Registration Workflow](https://docs.gitlab.com/ee/ci/runners/new_creation_workflow.html)

