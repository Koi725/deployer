# # 🚀 Deployer

**Zero-downtime Docker Compose deployments in one command.**

Stop writing custom deploy scripts for every project. Deployer handles git pull, image builds, rolling restarts, health checks, and rollback — all from a single CLI.

```bash
deployer push
```

---

## Why?

Every developer with a VPS has a messy `deploy.sh` they copy-paste between projects. Deployer replaces that with a clean, reusable tool that works with any Docker Compose project.

| Without Deployer | With Deployer |
|-----------------|---------------|
| SSH into server | `deployer push` |
| `git pull` in 3 repos | Handled automatically |
| `docker-compose build` | Handled automatically |
| Restart services manually | Rolling restart, zero downtime |
| Hope nothing breaks | Auto health check + rollback |
| No rollback plan | `deployer rollback` |

---

## Install

```bash
# Download
curl -sL https://raw.githubusercontent.com/Koi725/deployer/main/deployer.sh -o /usr/local/bin/deployer
chmod +x /usr/local/bin/deployer

# Or clone
git clone https://github.com/Koi725/deployer.git
cd deployer && sudo cp deployer.sh /usr/local/bin/deployer
```

---

## Quick Start

```bash
# 1. Go to your project directory (where docker-compose.yml lives)
cd /path/to/your/project

# 2. Initialize deployer
deployer init

# 3. Deploy
deployer push
```

That's it. Deployer will:
1. Pull latest code from all git repos
2. Backup current Docker images
3. Ensure infrastructure services are running
4. Build new images
5. Rolling restart each service (zero downtime)
6. Run health checks
7. Clean up old images

---

## Commands

```
deployer init          Interactive setup — detects your compose file and services
deployer push          Full deployment with zero downtime
deployer rollback      Revert to the previous deployment
deployer status        Show running containers
deployer logs [svc]    Tail logs (all services or specific one)
deployer health        Check if all services are healthy
deployer version       Show version
```

---

## How Rollback Works

Every `deployer push` automatically tags your current images before building new ones. If something goes wrong:

```bash
deployer rollback
```

This restores the previous images and recreates all containers. Your deployment log is saved in `.deployer.log`.

---

## Configuration

`deployer init` creates a `.deployer.conf` file:

```bash
DEPLOYER_COMPOSE_FILE="docker-compose.yml"
DEPLOYER_GIT_DIRS=".,./backend,./frontend"
DEPLOYER_HEALTH_URL="https://yourdomain.com/api/health"
DEPLOYER_SERVICES="backend frontend db redis"
```

Edit this file to customize behavior.

---

## Works With

- Any Docker Compose project
- Both `docker compose` (v2) and `docker-compose` (v1)
- Multiple git repositories in subdirectories
- Any VPS provider (Contabo, DigitalOcean, Hetzner, AWS, etc.)

---

## Example Output

```
═══════════════════════════════════════
  Deployer — Zero-Downtime Push
═══════════════════════════════════════

Step 1/6: Pulling latest code
  ✓ backend updated
  ✓ frontend updated

Step 2/6: Backing up current images
  ✓ Images tagged with backup-20260420-143022

Step 3/6: Ensuring infrastructure is running
  ✓ Infrastructure services confirmed

Step 4/6: Building new images
  ✓ All images built

Step 5/6: Rolling restart (zero downtime)
  ✓ backend is running
  ✓ frontend is running

Step 6/6: Health check
  ✓ Health check passed (HTTP 200)

═══════════════════════════════════════
  Deployment Complete
═══════════════════════════════════════
  Duration: 47s
  Rollback: deployer rollback
  Status:   deployer status
```

---

## License

MIT — use it however you want.

---

**Built by [Kousha Rezaei](https://kousharezaei.dev)** — Full-Stack Developer who got tired of writing the same deploy script for every project.

If this saved you time, give it a ⭐
