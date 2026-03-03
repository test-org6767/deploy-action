#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

parse_deploy_yaml() {
    local yaml_file="$1"
    local key="$2"

    if [[ ! -f "$yaml_file" ]]; then
        log_error "deploy.yaml not found at $yaml_file"
        return 1
    fi

    # Simple YAML parser - extracts value for key
    # Handles both "key: value" and list items like "ports: ['8080:80']"
    python3 -c "
import yaml
import sys
import json

try:
    with open('$yaml_file', 'r') as f:
        data = yaml.safe_load(f)

    # Navigate through nested keys if needed (e.g., 'deploy.ports')
    keys = '$key'.split('.')
    value = data
    for k in keys:
        if isinstance(value, dict):
            value = value.get(k)
        else:
            value = None
            break

    if value is None:
        sys.exit(1)

    if isinstance(value, list):
        print(json.dumps(value))
    else:
        print(value)
except Exception as e:
    sys.exit(1)
" 2>/dev/null || return 1
}

deploy_to_server() {
    local ssh_host="$1"
    local ssh_user="$2"
    local ssh_key="$3"
    local repo_url="$4"
    local repo_name="$5"
    local branch="${6:-main}"

    log_info "Starting deployment for $repo_name"

    local ssh_key_file
    ssh_key_file=$(mktemp)
    chmod 600 "$ssh_key_file"
    echo "$ssh_key" > "$ssh_key_file"

    local ssh_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30 -i $ssh_key_file"

    ssh $ssh_opts "${ssh_user}@${ssh_host}" /bin/bash << EOF
set -euo pipefail

REPO_URL="$repo_url"
REPO_NAME="$repo_name"
BRANCH="$branch"
DEPLOY_DIR="/var/apps/\${REPO_NAME}"
DEPLOY_YAML="\${DEPLOY_DIR}/deploy.yaml"
CONTAINER_NAME="\${REPO_NAME}"
IMAGE_NAME="\${REPO_NAME}:\$(git ls-remote \${REPO_URL} refs/heads/\${BRANCH} | awk '{print substr(\$1,1,12)}')"

echo "[INFO] Deploying \${REPO_NAME} from branch \${BRANCH}"
echo "[INFO] Image tag: \${IMAGE_NAME}"

mkdir -p "\$(dirname "\$DEPLOY_DIR")"

if [ -d "\$DEPLOY_DIR" ]; then
    echo "[INFO] Updating existing repository"
    cd "\$DEPLOY_DIR"
    git fetch origin
    git reset --hard "origin/\${BRANCH}"
    git clean -fd
else
    echo "[INFO] Cloning repository"
    git clone --depth 1 --single-branch --branch "\${BRANCH}" "\${REPO_URL}" "\$DEPLOY_DIR"
    cd "\$DEPLOY_DIR"
fi

if [[ -f "deploy.yaml" ]]; then
    echo "[INFO] Found deploy.yaml"
else
    echo "[WARN] No deploy.yaml found, using defaults"
fi

echo "[INFO] Building Docker image..."
docker build -t "\${IMAGE_NAME}" "\${DEPLOY_DIR}"

stop_container() {
    local container="\$1"
    if docker ps -a --format '{{.Names}}' | grep -q "^\${container}\$"; then
        echo "[INFO] Stopping existing container: \${container}"
        docker stop "\${container}" || true
        docker rm "\${container}" || true
    fi
}

stop_container "\${CONTAINER_NAME}"

DOCKER_CMD="docker run -d --name \${CONTAINER_NAME} --restart unless-stopped"

if [[ -f "deploy.yaml" ]]; then
    PORTS=\$(python3 -c "
import yaml
try:
    with open('deploy.yaml', 'r') as f:
        data = yaml.safe_load(f)
        if data and 'ports' in data and data['ports']:
            ports = data['ports']
            if isinstance(ports, list):
                print(' '.join([f'-p {p}' for p in ports]))
            elif isinstance(ports, str):
                print(f'-p {ports}')
except:
    pass
" 2>/dev/null || echo "")

    if [[ -n "\$PORTS" ]]; then
        DOCKER_CMD="\$DOCKER_CMD \$PORTS"
    fi
fi

if [[ -f "deploy.yaml" ]]; then
    VOLUMES=\$(python3 -c "
import yaml
try:
    with open('deploy.yaml', 'r') as f:
        data = yaml.safe_load(f)
        if data and 'volumes' in data and data['volumes']:
            vols = data['volumes']
            if isinstance(vols, list):
                print(' '.join([f'-v {v}' for v in vols]))
            elif isinstance(vols, str):
                print(f'-v {vols}')
except:
    pass
" 2>/dev/null || echo "")

    if [[ -n "\$VOLUMES" ]]; then
        DOCKER_CMD="\$DOCKER_CMD \$VOLUMES"
    fi
fi

if [[ -f "deploy.yaml" ]]; then
    ENV_VARS=\$(python3 -c "
import yaml
try:
    with open('deploy.yaml', 'r') as f:
        data = yaml.safe_load(f)
        if data and 'environment' in data and data['environment']:
            envs = data['environment']
            if isinstance(envs, dict):
                print(' '.join([f'-e {k}={v}' for k, v in envs.items()]))
except:
    pass
" 2>/dev/null || echo "")

    if [[ -n "\$ENV_VARS" ]]; then
        DOCKER_CMD="\$DOCKER_CMD \$ENV_VARS"
    fi
fi

echo "[INFO] Starting new container..."
eval "\$DOCKER_CMD \${IMAGE_NAME}"

sleep 3
if docker ps --format '{{.Names}}' | grep -q "^\${CONTAINER_NAME}\$"; then
    echo "[INFO] Container \${CONTAINER_NAME} started successfully!"

    echo ""
    echo "=== Container Status ==="
    docker ps --filter "name=\${CONTAINER_NAME}" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

    echo ""
    echo "[INFO] Cleaning up old images (keeping last 3)..."
    docker images "\${REPO_NAME}" --format "{{.ID}}" | tail -n +4 | xargs -r docker rmi -f || true

    exit 0
else
    echo "[ERROR] Container failed to start!"
    echo "[ERROR] Container logs:"
    docker logs "\${CONTAINER_NAME}" || true
    exit 1
fi
EOF

    local exit_code=$?

    rm -f "$ssh_key_file"

    if [[ $exit_code -eq 0 ]]; then
        log_info "Deployment completed successfully!"
    else
        log_error "Deployment failed with exit code $exit_code"
        return $exit_code
    fi
}

SSH_HOST="${HOST:-}"
SSH_USER="${SSH_USER:-root}"
SSH_KEY="${SSH_KEY:-}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"
GITHUB_REF="${GITHUB_REF:-}"

if [[ -z "$SSH_HOST" ]]; then
    log_error "SSH_HOST is required"
    exit 1
fi

if [[ -z "$SSH_KEY" ]]; then
    log_error "SSH_KEY is required"
    exit 1
fi

if [[ -z "$GITHUB_REPOSITORY" ]]; then
    log_error "GITHUB_REPOSITORY is required"
    exit 1
fi

BRANCH_NAME="main"
if [[ "$GITHUB_REF" =~ refs/heads/(.*) ]]; then
    BRANCH_NAME="${BASH_REMATCH[1]}"
fi

REPO_NAME=$(basename "$GITHUB_REPOSITORY")

REPO_URL="https://github.com/${GITHUB_REPOSITORY}.git"
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    REPO_URL="https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
fi

deploy_to_server "$SSH_HOST" "$SSH_USER" "$SSH_KEY" "$REPO_URL" "$REPO_NAME" "$BRANCH_NAME"
