# GitLab Deployment with Cloudflare

This guide explains how to deploy GitLab with Cloudflare proxy for SSL termination and DDoS protection.

## Architecture

```
User → Cloudflare (HTTPS) → Your Server (HTTPS:443 self-signed) → GitLab (HTTP:8080)
User → Cloudflare (HTTPS) → Your Server (HTTPS:443 self-signed) → Registry (HTTP:5050)
User → Direct SSH (DNS-only) → Your Server (SSH:22) → GitLab SSH
```

**Security:** Communication between Cloudflare and your server is encrypted with self-signed SSL certificate (Full Strict mode).

**Important:** SSH traffic bypasses Cloudflare proxy (uses DNS-only mode) because Cloudflare Proxied mode only supports HTTP/HTTPS traffic.

## Benefits

- ✅ Free SSL certificates from Cloudflare (for users)
- ✅ Encrypted connection between Cloudflare and server (self-signed cert)
- ✅ DDoS protection
- ✅ CDN caching for static assets
- ✅ No need for Let's Encrypt on server
- ✅ More secure than plain HTTP between Cloudflare and server
- ✅ Easy setup

## Prerequisites

- Domain registered in Cloudflare
- Server with Docker and Docker Compose
- Ports 22, 80, 443 open on server firewall

## Step 1: Cloudflare DNS Configuration

1. Go to Cloudflare Dashboard → Your Domain → DNS → Records

2. Create three A records:

   **GitLab Web Interface:**
   ```
   Type: A
   Name: git
   Content: YOUR_SERVER_IP
   Proxy status: Proxied (orange cloud) ✅
   TTL: Auto
   ```

   **Container Registry:**
   ```
   Type: A
   Name: registry
   Content: YOUR_SERVER_IP
   Proxy status: Proxied (orange cloud) ✅
   TTL: Auto
   ```

   **GitLab SSH (IMPORTANT!):**
   ```
   Type: A
   Name: git-ssh
   Content: YOUR_SERVER_IP
   Proxy status: DNS only (gray cloud) ⚠️ MUST BE GRAY!
   TTL: Auto
   ```

   **Why gray cloud for SSH?** Cloudflare Proxied mode (orange cloud) only supports HTTP/HTTPS traffic. SSH traffic must bypass Cloudflare proxy and go directly to your server.

3. Wait 1-5 minutes for DNS propagation

4. Verify DNS:
   ```bash
   dig git.yourdomain.com
   dig registry.yourdomain.com
   dig git-ssh.yourdomain.com
   ```

## Step 2: Cloudflare SSL/TLS Configuration

1. Go to Cloudflare Dashboard → SSL/TLS → Overview

2. Set encryption mode to **Full (Strict)** ⚠️ IMPORTANT!
   - This requires valid SSL certificate on your server (we'll use self-signed)
   - Provides encrypted connection between Cloudflare and your server
   - More secure than "Full" mode

3. Go to SSL/TLS → Edge Certificates

4. Enable **Always Use HTTPS**
   - This redirects all HTTP requests to HTTPS

5. (Optional) Enable **Automatic HTTPS Rewrites**

**Note:** We'll generate a self-signed certificate on the server in Step 4.

## Step 3: Cloudflare Security Settings (Optional)

1. Go to Security → Settings

2. Configure:
   - Security Level: **Medium** or **High**
   - Challenge Passage: **30 minutes**
   - Browser Integrity Check: **ON**

3. Go to Security → Bots
   - Enable **Bot Fight Mode** (free plan)

## Step 4: Server Configuration

### 4.1. Install Dependencies

```bash
# Update system
apt update && apt upgrade -y

# Install Docker
curl -fsSL https://get.docker.com | sh

# Install Docker Compose
apt install docker-compose-plugin -y

# Install Nginx
apt install nginx -y
```

### 4.2. Clone Repository

```bash
cd /var/www
git clone YOUR_REPO_URL gitlab
cd gitlab
```

### 4.3. Configure Environment

```bash
# Copy environment template
cp .env.sample .env

# Edit configuration
nano .env
```

**Update these values:**
```bash
GITLAB_HOSTNAME=git.yourdomain.com
# Cloudflare terminates TLS, so GitLab has to be told https - without this it
# generates http:// clone URLs and links. Note it also makes the session cookie
# Secure, so http://<host> stops being usable for login.
GITLAB_EXTERNAL_SCHEME=https
# Internal container hostname. Required once the scheme is https: Docker
# publishes this name to the whole network, so leaving it as the public name
# makes anything on that network - CI job containers registered by
# scripts/register-runner.sh among them - resolve it to the GitLab container
# and try 443, where its nginx does not listen. (A runner using
# network_per_build with an explicit clone_url is not affected either way.)
# On a plain-http setup you leave this unset instead - see .env.sample.
GITLAB_CONTAINER_HOSTNAME=gitlab
GITLAB_SSH_HOST=git-ssh.yourdomain.com
GITLAB_SSH_PORT=22
GITLAB_SSH_EXTERNAL_PORT=22
GITLAB_REGISTRY_EXTERNAL_URL=https://registry.yourdomain.com
GITLAB_ROOT_PASSWORD=YourStrongPassword123!

# Email settings (MailerSend)
SMTP_USERNAME=your-mailersend-username
SMTP_PASSWORD=your-mailersend-password
GITLAB_EMAIL_FROM=gitlab@yourdomain.com
GITLAB_EMAIL_REPLY_TO=noreply@yourdomain.com
```

Save: `Ctrl+O`, `Enter`, `Ctrl+X`

### 4.4. Generate Self-Signed SSL Certificate

```bash
# Run certificate generation script
./scripts/generate-self-signed-cert.sh

# Enter your domains when prompted:
# - GitLab domain: git.yourdomain.com
# - Registry domain: registry.yourdomain.com
```

This creates:
- `/etc/nginx/ssl/gitlab.crt` - Certificate (valid for 10 years)
- `/etc/nginx/ssl/gitlab.key` - Private key

### 4.5. Configure Nginx

```bash
# Copy Cloudflare nginx config
cp nginx/gitlab-cloudflare.conf /etc/nginx/sites-available/gitlab

# Edit if needed (change domain names)
nano /etc/nginx/sites-available/gitlab

# Enable site
ln -s /etc/nginx/sites-available/gitlab /etc/nginx/sites-enabled/

# Test configuration
nginx -t

# Reload Nginx
systemctl reload nginx
```

### 4.6. Configure Firewall

```bash
# Allow HTTP and HTTPS (Cloudflare will connect here)
ufw allow 80/tcp
ufw allow 443/tcp

# Allow SSH for Git operations (standard SSH port)
ufw allow 22/tcp

# Check status
ufw status
```

**Important:**
- Do NOT open port 8080 or 5050 to public!
- Port 22 is used for GitLab SSH (git clone/push/pull)
- If you need SSH access to the server itself, configure it on a different port (e.g., 2222) before enabling firewall

### 4.7. Start GitLab

```bash
# Start services
docker compose up -d

# Check logs
docker compose logs -f gitlab
```

Wait for message: `gitlab Reconfigured!` (takes 3-5 minutes)

## Step 5: Access GitLab

1. Open browser: `https://git.yourdomain.com`

2. Login:
   - Username: `root`
   - Password: From `.env` file

3. Change root password in UI

## Step 6: Test SSH Access

```bash
# Test SSH connection
ssh -T git@git-ssh.yourdomain.com

# Expected output:
# Welcome to GitLab, @username!
```

**Clone repository:**
```bash
git clone git@git-ssh.yourdomain.com:group/project.git
```

**Note:** No port needed! Standard SSH port 22 is used.

## Step 7: Test Container Registry

```bash
# Login to registry
docker login registry.yourdomain.com

# Tag an image
docker tag myimage:latest registry.yourdomain.com/group/project/myimage:latest

# Push image
docker push registry.yourdomain.com/group/project/myimage:latest
```

## Step 8: Register GitLab Runner

```bash
./scripts/register-runner.sh
```

The script will automatically detect your production setup and show the correct URL (`https://git.yourdomain.com`).

**Get registration token:**
1. Go to `https://git.yourdomain.com`
2. Login as root
3. Go to **Admin Area** → **CI/CD** → **Runners**
4. Click **New instance runner**
5. Select **Linux** platform
6. Copy the registration token (starts with `glrt-`)
7. Paste it when prompted by the script

**Configure runner after registration:**
1. Go to **Admin Area** → **CI/CD** → **Runners**
2. Find your runner and click **Edit**
3. Configure:
   - **Description**: `docker-runner` (or any name)
   - **Tags**: `docker`, `linux`, `arm64`
   - **Run untagged jobs**: Enable if needed

**Important:**
- GitLab 16.0+ changed runner registration workflow. Tags and description are now configured in the UI.
- The runner communicates with GitLab via internal Docker network (`http://gitlab`), not via your external domain. This is correct and secure - all communication stays within the Docker network.

## Troubleshooting

### DNS not resolving

- Wait 5-10 minutes for DNS propagation
- Check Cloudflare DNS records are correct
- Verify proxy status is "Proxied" (orange cloud)

### 502 Bad Gateway

- Check GitLab is running: `docker compose ps`
- Check Nginx is running: `systemctl status nginx`
- Check Nginx logs: `tail -f /var/log/nginx/error.log`
- Verify port 8080 is listening: `netstat -tlnp | grep 8080`

### SSL/TLS errors

- Verify Cloudflare SSL mode is set to "Full"
- Check Nginx config has `X-Forwarded-Proto https` header
- Clear browser cache and try incognito mode

### Container Registry not working

- Verify `GITLAB_REGISTRY_EXTERNAL_URL` in `.env` is set correctly
- Check registry subdomain DNS is configured
- Restart GitLab: `docker compose restart gitlab`

### Email not sending

- Verify MailerSend credentials in `.env`
- Check domain is verified in MailerSend
- Test email: `docker exec -it gitlab gitlab-rails console`
  ```ruby
  Notify.test_email('test@example.com', 'Test', 'Test').deliver_now
  ```

## Maintenance

### Update GitLab

```bash
cd /var/www/gitlab
docker compose pull
docker compose up -d
```

### Backup

```bash
make backup
```

### View Logs

```bash
make logs
```

## Security Recommendations

1. Change default root password immediately
2. Enable 2FA for root account
3. Disable public sign-ups (Admin → Settings → Sign-up restrictions)
4. Configure rate limiting in Cloudflare
5. Enable Cloudflare WAF rules (paid plans)
6. Regularly update GitLab: `docker compose pull && docker compose up -d`

## Support

- [GitLab Documentation](https://docs.gitlab.com/)
- [Cloudflare Documentation](https://developers.cloudflare.com/)
- [Docker Documentation](https://docs.docker.com/)

