# GitHub Package Webhook Listener

A small Node.js service that listens for GitHub **Package** webhook events and automatically pulls a new container image from GHCR and redeploys your app on a DigitalOcean VPS.

## How it works

1. GitHub sends a POST request to your VPS when a package is published or updated.
2. The listener verifies the `X-Hub-Signature-256` header.
3. For container packages matching your filters, it runs `scripts/deploy-container.sh` to `docker pull` and restart your stack.

Supported webhook events: `package` (recommended) and legacy `registry_package`.

## Project layout

```
src/server.js              Express app and webhook route
src/verifySignature.js     HMAC SHA-256 verification
src/handlePackageEvent.js  Package event filtering and deploy trigger
scripts/deploy-container.sh Docker pull + compose up / restart
deploy/webhook.service     systemd unit template
deploy/nginx-site.conf     Nginx reverse proxy template
Dockerfile                 Sample app image published to GHCR
.github/workflows/publish-package.yml  Triggers package webhook
docker-compose.example.yml Example stack for the VPS
```

## Trigger a Package webhook event

Publishing a container image to GHCR from this repo triggers the **Package** webhook (`published` / `updated`).

This repo includes:

- `Dockerfile` — minimal nginx sample app
- `.github/workflows/publish-package.yml` — builds and pushes `ghcr.io/filipehb/my-app:latest`

### One-time: make the GHCR package public (optional)

After the first publish, go to **GitHub → Your profile → Packages → my-app → Package settings** and set visibility if you need public pulls without auth.

For a private VPS deploy, keep the package private and use `docker login ghcr.io` on the VPS instead.

### Run the publish workflow

1. Commit and push these files to `main`, **or**
2. In GitHub: **Actions → Publish container package → Run workflow**

The workflow pushes:

```
ghcr.io/filipehb/my-app:latest
```

That matches the default filters in `.env.example` (`PACKAGE_OWNER`, `PACKAGE_NAME`, `IMAGE_TAG`).

### Verify the webhook fired

1. **Settings → Webhooks → Recent Deliveries** — look for a `package` event with response `200`
2. Webhook listener logs — `[package] Triggering deploy for ghcr.io/filipehb/my-app:latest`
3. If using ngrok locally, keep `npm start` running while the workflow completes

### Manual trigger from your machine (alternative)

```bash
docker build -t ghcr.io/filipehb/my-app:latest .
echo "$GHCR_TOKEN" | docker login ghcr.io -u filipehb --password-stdin
docker push ghcr.io/filipehb/my-app:latest
```

Use a PAT with `write:packages` scope. Pushing from your machine also triggers the webhook if the package is linked to this repository.

## Local development

```bash
npm install
cp .env.example .env
# Edit .env and set WEBHOOK_SECRET
npm start
```

Health check: `GET http://localhost:3000/health`

## GitHub webhook setup

In your repository: **Settings → Webhooks → Add webhook**

| Field | Value |
|-------|-------|
| Payload URL | `https://YOUR_DOMAIN/webhook/github` (must include `/webhook/github`) |
| Content type | `application/json` (form-urlencoded also supported) |
| Secret | Same value as `WEBHOOK_SECRET` in `.env` |
| Events | Select **Package** (published / updated) |
| Active | Yes |

After saving, GitHub sends a **ping** event. Your server must return HTTP 200.

Docs: [Creating webhooks](https://docs.github.com/en/webhooks/using-webhooks/creating-webhooks)

## Environment variables

Copy `.env.example` to `.env` on your VPS:

| Variable | Description |
|----------|-------------|
| `PORT` | Local port (default `3000`) |
| `WEBHOOK_SECRET` | GitHub webhook secret |
| `PACKAGE_OWNER` | Optional filter, e.g. `filipehb` |
| `PACKAGE_NAME` | Optional filter, e.g. `my-app` |
| `IMAGE_TAG` | Optional filter, e.g. `latest` or `v*` |
| `COMPOSE_FILE` | Path to docker-compose file for redeploy |
| `CONTAINER_NAME` | Alternative to compose: restart this container |
| `GHCR_USERNAME` | For `docker login ghcr.io` on the VPS |
| `GHCR_TOKEN` | PAT with `read:packages` (VPS only, not used by Node) |

Leave filter variables empty to accept any container package event.

## DigitalOcean VPS deployment

### 1. Install prerequisites

On Ubuntu 22.04+:

```bash
sudo apt update
sudo apt install -y nginx certbot python3-certbot-nginx
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs docker.io docker-compose-plugin
```

Point your domain's DNS A record to the droplet IP.

### 2. GHCR login

Create a fine-grained PAT with **read access to packages**, then on the VPS:

```bash
echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USERNAME" --password-stdin
```

### 3. Deploy the webhook service

```bash
sudo useradd --system --home /opt/github-webhook --shell /usr/sbin/nologin webhook || true
sudo mkdir -p /opt/github-webhook
sudo chown webhook:webhook /opt/github-webhook

git clone git@github.com:filipehb/poc_github_webhook_package.git /opt/github-webhook
cd /opt/github-webhook
npm ci
cp .env.example .env
# Edit .env with your secrets and filters
chmod +x scripts/deploy-container.sh
```

Add the webhook user to the docker group if it needs to run Docker:

```bash
sudo usermod -aG docker webhook
```

Install and start systemd service:

```bash
sudo cp deploy/webhook.service /etc/systemd/system/github-webhook.service
sudo systemctl daemon-reload
sudo systemctl enable --now github-webhook
sudo systemctl status github-webhook
```

### 4. Nginx and TLS

```bash
sudo cp deploy/nginx-site.conf /etc/nginx/sites-available/github-webhook
sudo ln -s /etc/nginx/sites-available/github-webhook /etc/nginx/sites-enabled/
# Edit server_name in the config first
sudo nginx -t && sudo systemctl reload nginx
sudo certbot --nginx -d your-domain.com
```

### 5. Firewall

```bash
sudo ufw allow OpenSSH
sudo ufw allow 'Nginx Full'
sudo ufw enable
```

Do not expose port 3000 publicly; only Nginx should proxy to it.

## Testing

### Test with ngrok (before VPS is ready)

```bash
npm start
ngrok http 3000
```

Use the ngrok HTTPS URL as the GitHub webhook Payload URL. Confirm the **ping** delivery succeeds in GitHub webhook settings.

### Test a real package publish

Push a new container image tag to GHCR linked to your repo. Check VPS logs:

```bash
sudo journalctl -u github-webhook -f
```

You should see a `package` event and deploy script output.

## Security notes

- Always verify `X-Hub-Signature-256` (implemented in `src/verifySignature.js`).
- Never commit `.env` or tokens.
- Run the service as a non-root user.
- Signature verification is the primary guard; optionally add GitHub IP allow lists in Nginx.

## Troubleshooting

| Issue | Check |
|-------|-------|
| Webhook ping fails | HTTPS reachable? Nginx proxy correct? `WEBHOOK_SECRET` matches GitHub? |
| 401 Invalid signature | Secret mismatch or body parsed before verification |
| Package event ignored | Filters in `.env`? Is `package_type` `container`? |
| Docker pull fails | `docker login ghcr.io` on VPS? PAT has `read:packages`? |
| `no matching manifest for linux/arm64` on Mac | Re-run publish workflow (multi-arch build), or set `DOCKER_PLATFORM=linux/amd64` in `.env` for local testing |
| Deploy script fails | `COMPOSE_FILE` or `CONTAINER_NAME` set? User in `docker` group? |
