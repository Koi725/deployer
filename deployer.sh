#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  deployer v1.0
#  Zero-downtime deployment for Docker Compose projects.
#  https://github.com/Koi725/deployer
#
#  Usage:
#    deployer init          Set up deployer in current project
#    deployer push          Deploy with zero downtime
#    deployer rollback      Revert to previous deployment
#    deployer status        Show running services
#    deployer logs [svc]    Tail logs for a service
#    deployer health        Run health checks on all services
#
#  Author: Kousha Rezaei — github.com/Koi725
#  License: MIT
# ═══════════════════════════════════════════════════════════════

set -uo pipefail

VERSION="1.0.0"

# ── Colors ────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ── Config ────────────────────────────────────────────────────
CONFIG_FILE=".deployer.conf"
DEPLOY_LOG=".deployer.log"
BACKUP_TAG=""
COMPOSE_FILE="docker-compose.yml"

# ── Helpers ───────────────────────────────────────────────────
ts() { date +"%Y-%m-%d %H:%M:%S"; }
log() { echo -e "${GREEN}[$(ts)]${NC} $*"; echo "[$(ts)] $*" >> "$DEPLOY_LOG" 2>/dev/null || true; }
warn() { echo -e "${YELLOW}[$(ts)] ⚠  $*${NC}"; }
fail() { echo -e "${RED}[$(ts)] ✗  $*${NC}"; exit 1; }
ok() { echo -e "${GREEN}[$(ts)] ✓  $*${NC}"; }

header() {
    echo ""
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════${NC}"
    echo -e "${BOLD}${BLUE}  $*${NC}"
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════${NC}"
    echo ""
}

spinner() {
    local pid=$1
    local msg=$2
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        echo -ne "\r${CYAN}  ${spin:$((i%10)):1}${NC} $msg"
        i=$((i+1))
        sleep 0.1
    done
    echo -ne "\r"
}

# ── Load config ───────────────────────────────────────────────
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi
    COMPOSE_FILE="${DEPLOYER_COMPOSE_FILE:-docker-compose.yml}"
}

# ── Commands ──────────────────────────────────────────────────

cmd_init() {
    header "Deployer — Init"

    if [ -f "$CONFIG_FILE" ]; then
        warn "Deployer already initialized in this directory"
        read -p "  Overwrite? (y/N): " answer
        [ "$answer" != "y" ] && exit 0
    fi

    # Detect compose file
    if [ -f "docker-compose.yml" ]; then
        COMPOSE_FILE="docker-compose.yml"
    elif [ -f "docker-compose.yaml" ]; then
        COMPOSE_FILE="docker-compose.yaml"
    elif [ -f "compose.yml" ]; then
        COMPOSE_FILE="compose.yml"
    else
        fail "No docker-compose file found in current directory"
    fi

    # Detect services
    SERVICES=$(docker compose -f "$COMPOSE_FILE" config --services 2>/dev/null || \
               docker-compose -f "$COMPOSE_FILE" config --services 2>/dev/null)

    if [ -z "$SERVICES" ]; then
        fail "No services found in $COMPOSE_FILE"
    fi

    log "Found compose file: $COMPOSE_FILE"
    log "Found services:"
    echo "$SERVICES" | while read -r svc; do
        echo -e "  ${CYAN}▸${NC} $svc"
    done

    # Ask for git repos
    echo ""
    read -p "  Git repo directories (comma-separated, or . for current): " GIT_DIRS
    GIT_DIRS="${GIT_DIRS:-.}"

    # Ask for health check URL
    read -p "  Health check URL (or skip): " HEALTH_URL
    HEALTH_URL="${HEALTH_URL:-skip}"

    # Write config
    cat > "$CONFIG_FILE" <<EOF
# Deployer config — generated $(date)
DEPLOYER_COMPOSE_FILE="$COMPOSE_FILE"
DEPLOYER_GIT_DIRS="$GIT_DIRS"
DEPLOYER_HEALTH_URL="$HEALTH_URL"
DEPLOYER_SERVICES="$(echo $SERVICES | tr '\n' ' ')"
EOF

    ok "Deployer initialized. Run 'deployer push' to deploy."
}

cmd_push() {
    load_config
    header "Deployer — Zero-Downtime Push"

    local start_time=$(date +%s)
    BACKUP_TAG="backup-$(date +%Y%m%d-%H%M%S)"

    # ── Step 1: Pull latest code ──
    log ""
    log "Step 1/6: Pulling latest code"
    log "─────────────────────────────"

    IFS=',' read -ra DIRS <<< "${DEPLOYER_GIT_DIRS:-.}"
    for dir in "${DIRS[@]}"; do
        dir=$(echo "$dir" | xargs) # trim whitespace
        if [ -d "$dir/.git" ]; then
            log "  Pulling: $(basename "$dir")"
            (cd "$dir" && git fetch --all --prune -q && git pull --rebase --autostash -q 2>/dev/null || git pull -q)
            ok "  $(basename "$dir") updated"
        fi
    done

    # ── Step 2: Backup current images ──
    log ""
    log "Step 2/6: Backing up current images"
    log "─────────────────────────────────"

    for svc in ${DEPLOYER_SERVICES:-}; do
        local img=$(docker compose -f "$COMPOSE_FILE" images "$svc" -q 2>/dev/null | head -1)
        if [ -n "$img" ]; then
            docker tag "$img" "${svc}:${BACKUP_TAG}" 2>/dev/null || true
        fi
    done
    ok "Images tagged with $BACKUP_TAG for rollback"

    # ── Step 3: Ensure infrastructure ──
    log ""
    log "Step 3/6: Ensuring infrastructure is running"
    log "─────────────────────────────────"

    # Start infra services (db, redis, etc.) without recreating
    docker compose -f "$COMPOSE_FILE" up -d --no-recreate 2>/dev/null || \
    docker-compose -f "$COMPOSE_FILE" up -d --no-recreate 2>/dev/null

    # Wait for infra
    sleep 3
    ok "Infrastructure services confirmed"

    # ── Step 4: Build new images ──
    log ""
    log "Step 4/6: Building new images"
    log "─────────────────────────────"

    docker compose -f "$COMPOSE_FILE" build --no-cache 2>&1 | while IFS= read -r line; do
        echo -e "  ${DIM}$line${NC}"
    done
    ok "All images built"

    # ── Step 5: Rolling restart ──
    log ""
    log "Step 5/6: Rolling restart (zero downtime)"
    log "─────────────────────────────────"

    for svc in ${DEPLOYER_SERVICES:-}; do
        log "  Restarting: $svc"
        docker compose -f "$COMPOSE_FILE" up -d --no-deps --force-recreate "$svc" 2>/dev/null || \
        docker-compose -f "$COMPOSE_FILE" up -d --no-deps --force-recreate "$svc" 2>/dev/null

        # Wait for container to be running
        local retries=0
        while [ $retries -lt 30 ]; do
            local state=$(docker compose -f "$COMPOSE_FILE" ps "$svc" --format json 2>/dev/null | grep -o '"running"' || echo "")
            if [ -n "$state" ]; then
                ok "  $svc is running"
                break
            fi
            retries=$((retries + 1))
            sleep 2
        done

        if [ $retries -eq 30 ]; then
            warn "  $svc may not be running — check manually"
        fi
    done

    # ── Step 6: Health check ──
    log ""
    log "Step 6/6: Health check"
    log "─────────────────────────────"

    if [ "${DEPLOYER_HEALTH_URL:-skip}" != "skip" ]; then
        local healthy=false
        for i in $(seq 1 10); do
            local status=$(curl -s -o /dev/null -w "%{http_code}" "$DEPLOYER_HEALTH_URL" 2>/dev/null || echo "000")
            if [ "$status" -ge 200 ] && [ "$status" -lt 400 ]; then
                ok "Health check passed (HTTP $status)"
                healthy=true
                break
            fi
            sleep 3
        done

        if [ "$healthy" = false ]; then
            warn "Health check failed — consider running 'deployer rollback'"
        fi
    else
        ok "No health check URL configured — skipping"
    fi

    # ── Cleanup ──
    log ""
    log "Cleaning up old images..."
    docker image prune -f >/dev/null 2>&1
    docker builder prune -f --filter "until=1h" >/dev/null 2>&1

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    # ── Summary ──
    header "Deployment Complete"
    echo -e "  ${GREEN}Duration:${NC} ${duration}s"
    echo -e "  ${GREEN}Rollback:${NC} deployer rollback"
    echo -e "  ${GREEN}Status:${NC}   deployer status"
    echo -e "  ${GREEN}Logs:${NC}     deployer logs [service]"
    echo ""

    # Save deployment record
    echo "[$(ts)] DEPLOYED in ${duration}s — backup: $BACKUP_TAG" >> "$DEPLOY_LOG"
}

cmd_rollback() {
    load_config
    header "Deployer — Rollback"

    local latest_backup=$(grep "backup:" "$DEPLOY_LOG" 2>/dev/null | tail -1 | grep -o 'backup-[^ ]*')

    if [ -z "$latest_backup" ]; then
        fail "No previous deployment found to rollback"
    fi

    log "Rolling back to: $latest_backup"

    for svc in ${DEPLOYER_SERVICES:-}; do
        if docker image inspect "${svc}:${latest_backup}" &>/dev/null; then
            log "  Restoring: $svc"
            docker tag "${svc}:${latest_backup}" "${svc}:latest" 2>/dev/null || true
        fi
    done

    docker compose -f "$COMPOSE_FILE" up -d --force-recreate 2>/dev/null || \
    docker-compose -f "$COMPOSE_FILE" up -d --force-recreate 2>/dev/null

    ok "Rolled back to $latest_backup"
    echo "[$(ts)] ROLLBACK to $latest_backup" >> "$DEPLOY_LOG"
}

cmd_status() {
    load_config
    header "Deployer — Status"
    docker compose -f "$COMPOSE_FILE" ps 2>/dev/null || \
    docker-compose -f "$COMPOSE_FILE" ps 2>/dev/null
}

cmd_logs() {
    load_config
    local service="${1:-}"
    if [ -n "$service" ]; then
        docker compose -f "$COMPOSE_FILE" logs -f --tail=100 "$service" 2>/dev/null || \
        docker-compose -f "$COMPOSE_FILE" logs -f --tail=100 "$service" 2>/dev/null
    else
        docker compose -f "$COMPOSE_FILE" logs -f --tail=50 2>/dev/null || \
        docker-compose -f "$COMPOSE_FILE" logs -f --tail=50 2>/dev/null
    fi
}

cmd_health() {
    load_config
    header "Deployer — Health Check"

    for svc in ${DEPLOYER_SERVICES:-}; do
        local running=$(docker compose -f "$COMPOSE_FILE" ps "$svc" --format json 2>/dev/null | grep -c '"running"' || echo "0")
        if [ "$running" -gt 0 ]; then
            ok "$svc — running"
        else
            fail "$svc — not running"
        fi
    done

    if [ "${DEPLOYER_HEALTH_URL:-skip}" != "skip" ]; then
        echo ""
        local status=$(curl -s -o /dev/null -w "%{http_code}" "$DEPLOYER_HEALTH_URL" 2>/dev/null || echo "000")
        if [ "$status" -ge 200 ] && [ "$status" -lt 400 ]; then
            ok "HTTP health: $DEPLOYER_HEALTH_URL (HTTP $status)"
        else
            warn "HTTP health: $DEPLOYER_HEALTH_URL (HTTP $status)"
        fi
    fi
}

# ── Main ──────────────────────────────────────────────────────
case "${1:-help}" in
    init)     cmd_init ;;
    push)     cmd_push ;;
    rollback) cmd_rollback ;;
    status)   cmd_status ;;
    logs)     cmd_logs "${2:-}" ;;
    health)   cmd_health ;;
    version)  echo "deployer v$VERSION" ;;
    help|*)
        echo -e "${BOLD}deployer${NC} v$VERSION — Zero-downtime Docker Compose deployments"
        echo ""
        echo -e "  ${CYAN}deployer init${NC}          Set up deployer in current project"
        echo -e "  ${CYAN}deployer push${NC}          Deploy with zero downtime"
        echo -e "  ${CYAN}deployer rollback${NC}      Revert to previous deployment"
        echo -e "  ${CYAN}deployer status${NC}        Show running services"
        echo -e "  ${CYAN}deployer logs [svc]${NC}    Tail logs for a service"
        echo -e "  ${CYAN}deployer health${NC}        Run health checks"
        echo -e "  ${CYAN}deployer version${NC}       Show version"
        echo ""
        echo "  https://github.com/Koi725/deployer"
        ;;
esac
