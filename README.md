# Docker SSH Deploy Action

> Deploy Docker containers to your server via SSH with zero code on the server.

A GitHub Action that deploys your Dockerized application to a remote server. Simply add a `Dockerfile` and `deploy.yaml` to your repo, and this action handles the rest.

## Features

- Zero server-side code - only Docker + SSH required on the server
- Automatic builds - builds Docker image from repo on each deploy
- Auto-update - pulls code and rebuilds on push
- Сonfig - configure ports, volumes, and env vars via YAML
- Cleanup - automatically removes old images, keeps last 3
- Secure - uses SSH keys, supports private repos
- Deploy per commit - image tagged with commit SHA

## Prerequisites

### On server:

1. Docker installed
   ```bash
   curl -fsSL https://get.docker.com | sh
   ```

2. SSH access with key-based authentication

3. User permissions — the SSH user needs Docker permissions
   ```bash
   sudo usermod -aG docker your-user
   ```

### In GitHub:

1. Organization secrets configured (recommended):
   - `DEPLOY_HOST` — your server hostname/IP
   - `DEPLOY_SSH_USER` — your SSH user (optional, defaults to `root`)
   - `DEPLOY_SSH_KEY` — your private SSH key

## Quick Start

### 1. Add `deploy.yaml` to your repo

Create a `deploy.yaml` in your repo root:

```yaml
name: myapp
ports:
  - "8080:80"
volumes:
  - "/var/data/myapp:/app/data"
environment:
  ENV: production
  DEBUG: "false"
```

### 2. Create the workflow

Create `.github/workflows/deploy.yml`:

```yaml
name: Deploy to Production
on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: org/deploy-action@v1
        with:
          host: ${{ secrets.DEPLOY_HOST }}
          ssh-user: ${{ secrets.DEPLOY_SSH_USER }}  # optional, defaults to root
          ssh-key: ${{ secrets.DEPLOY_SSH_KEY }}
```

### 3. Push and done

```bash
git add .
git commit -m "Add deployment config"
git push origin main
```

Your app will be deployed automatically! 🎉

## 📖 Configuration

### `deploy.yaml` reference

| Field | Type | Description | Example |
|-------|------|-------------|---------|
| `name` | string | Application name (defaults to repo name) | `myapp` |
| `ports` | array | Port mappings (host:container) | `["8080:80", "3000:3000"]` |
| `volumes` | array | Volume mounts (host:container) | `["/data:/app/data"]` |
| `environment` | object | Environment variables | `{ENV: "prod", API_KEY: "xxx"}` |
| `restart` | string | Restart policy (not yet implemented) | `always` |

### Action inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `host` | Yes | - | Server hostname or IP address |
| `ssh-user` | No | `root` | SSH user |
| `ssh-key` | Yes | - | SSH private key (add to secrets) |
| `github-token` | No | `GITHUB_TOKEN` | GitHub token for private repos |
| `branch` | No | current branch | Branch to deploy |

## Setting up secrets

### Option 1: Organization secrets

For all repos in your organization:

1. Go to Settings → Secrets and variables → Actions
2. Click *New repository secret*
3. Add secrets:
   - `DEPLOY_HOST` = `your-server.com` or `192.168.1.100`
   - `DEPLOY_SSH_USER` = `deploy-user` (optional, defaults to `root`)
   - `DEPLOY_SSH_KEY` = contents of your private key file

### Option 2: Repository secrets

For a single repo:

1. Go to your repository
2. **Settings** → **Secrets and variables** → **Actions**
3. Add the same secrets as above

### Generating SSH key pair

If you don't have SSH keys:

```bash
# Generate key pair
ssh-keygen -t ed25519 -C "github-deploy" -f ~/.ssh/github_deploy

# Copy public key to server
ssh-copy-id -i ~/.ssh/github_deploy.pub user@your-server.com

# Copy private key contents to GitHub secrets
cat ~/.ssh/github_deploy
```

## 📚 Examples

### Basic Node.js app

**Dockerfile:**
```dockerfile
FROM node:20-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production
COPY . .
CMD ["node", "index.js"]
```

**deploy.yaml:**
```yaml
ports:
  - "3000:3000"
environment:
  NODE_ENV: production
```

### Python app with database volume

**Dockerfile:**
```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY . .
CMD ["python", "app.py"]
```

**deploy.yaml:**
```yaml
ports:
  - "8000:8000"
volumes:
  - "/var/data/myapp/db:/app/db"
environment:
  PYTHONUNBUFFERED: "1"
```

### Multi-port app (web + admin)

**deploy.yaml:**
```yaml
ports:
  - "80:8080"    # main app
  - "8081:8081"  # admin panel
volumes:
  - "/var/uploads:/app/uploads"
  - "/var/config:/app/config"
environment:
  APP_PORT: 8080
  ADMIN_PORT: 8081
```

### Manual deploy with branch selection

```yaml
name: Deploy Staging
on:
  workflow_dispatch:
    inputs:
      branch:
        description: 'Branch to deploy'
        required: true
        default: 'develop'

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          ref: ${{ github.event.inputs.branch }}

      - uses: your-org/deploy-action@v1
        with:
          host: ${{ secrets.STAGING_HOST }}
          ssh-key: ${{ secrets.DEPLOY_SSH_KEY }}
          branch: ${{ github.event.inputs.branch }}
```

## 🛠️ How it works

```
┌─────────────────────────────────────────────────────────┐
│                    GitHub Actions                        │
│  ┌────────────────────────────────────────────────────┐ │
│  │  1. Clone your repo                                │ │
│  │  2. Read deploy.yaml                               │ │
│  │  3. SSH to server                                  │ │
│  └────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
                         │
                    SSH (key)
                         │
                         ▼
              ┌─────────────────────┐
              │  Your Server        │
              │  ┌───────────────┐  │
              │  │ 1. git pull   │  │
              │  │ 2. docker bu ild│  │
              │  │ 3. docker stop│  │
              │  │ 4. docker run │  │
              │  └───────────────┘  │
              └─────────────────────┘
```

### Deployment process:

1. **Clone** — Action clones your repo to `/var/apps/<appname>`
2. **Build** — Docker image built as `<appname>:<commit-sha>`
3. **Stop** — Old container stopped and removed
4. **Run** — New container started with config from `deploy.yaml`
5. **Cleanup** — Old images removed (keeps last 3)

## 🐛 Troubleshooting

### Container fails to start

Check the logs in the GitHub Actions output. The action will show container logs on failure.

### Permission denied

Make sure your SSH user has Docker permissions:
```bash
sudo usermod -aG docker your-user
```

### SSH connection refused

Check that:
- SSH key is correctly added to secrets
- Server SSH port is accessible
- User exists on server

### Private repository issues

Make sure to pass `github-token` input (defaults to `GITHUB_TOKEN`).

## 🔄 Roadmap

- [ ] Healthcheck support (wait for container to be healthy)
- [ ] Rollback on failure
- [ ] Support for docker-compose.yml
- [ ] Multi-server deployment
- [ ] Pre/post deploy hooks

## 📝 License

MIT

## 🤝 Contributing

Contributions welcome! Feel free to open issues or PRs.
