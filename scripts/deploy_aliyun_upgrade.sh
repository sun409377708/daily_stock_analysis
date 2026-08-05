#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DSA_SERVER_HOST="${DSA_SERVER_HOST:-8.130.132.215}"
DSA_SERVER_USER="${DSA_SERVER_USER:-root}"
DSA_SERVER_PORT="${DSA_SERVER_PORT:-22}"
DSA_SERVER_PATH="${DSA_SERVER_PATH:-/opt/daily-stock-analysis}"
DSA_SERVICE_NAME="${DSA_SERVICE_NAME:-daily-stock-analysis}"
DSA_HEALTH_URL="${DSA_HEALTH_URL:-https://stock.jianqin.fun/api/health}"
DSA_BACKUP_DIR="${DSA_BACKUP_DIR:-/opt/backups}"
DSA_ALLOW_DIRTY="${DSA_ALLOW_DIRTY:-1}"
DSA_SKIP_PULL="${DSA_SKIP_PULL:-1}"
DSA_SKIP_FRONTEND_BUILD="${DSA_SKIP_FRONTEND_BUILD:-0}"

ssh_cmd=(ssh -p "$DSA_SERVER_PORT" -o StrictHostKeyChecking=no -o ConnectTimeout=10)
rsync_ssh=(ssh -p "$DSA_SERVER_PORT" -o StrictHostKeyChecking=no)

if [[ -n "${DSA_SSH_PASS:-}" ]]; then
  if ! command -v sshpass >/dev/null 2>&1; then
    echo "DSA_SSH_PASS is set, but sshpass is not installed." >&2
    exit 1
  fi
  ssh_cmd=(sshpass -p "$DSA_SSH_PASS" "${ssh_cmd[@]}")
  rsync_ssh=(sshpass -p "$DSA_SSH_PASS" "${rsync_ssh[@]}")
fi

remote="${DSA_SERVER_USER}@${DSA_SERVER_HOST}"

run_remote() {
  "${ssh_cmd[@]}" "$remote" "$@"
}

echo "Repository: $ROOT_DIR"
echo "Target: ${remote}:${DSA_SERVER_PATH}"

cd "$ROOT_DIR"

if [[ "$DSA_SKIP_PULL" != "1" ]]; then
  git fetch --tags origin
  if [[ -n "$(git status --porcelain)" && "$DSA_ALLOW_DIRTY" != "1" ]]; then
    echo "Working tree is dirty. Set DSA_ALLOW_DIRTY=1 to deploy current local changes." >&2
    git status --short
    exit 1
  fi
  git pull --ff-only
else
  echo "Skipping git pull. Set DSA_SKIP_PULL=0 after reapplying local patches if you want the script to pull."
fi

echo "Running Python compile checks..."
PYTHON_BIN="${PYTHON_BIN:-$ROOT_DIR/.venv/bin/python}"
if [[ ! -x "$PYTHON_BIN" ]]; then
  PYTHON_BIN="${PYTHON_BIN_FALLBACK:-python3}"
fi
PYTHONPYCACHEPREFIX=/tmp/dsa-pycache "$PYTHON_BIN" -m py_compile \
  main.py \
  server.py \
  api/app.py \
  api/v1/endpoints/analysis.py \
  api/v1/endpoints/screening.py \
  api/v1/schemas/portfolio.py \
  src/config.py \
  src/storage.py \
  src/services/portfolio_risk_service.py \
  src/services/portfolio_service.py \
  src/services/screening_service.py

if [[ "$DSA_SKIP_FRONTEND_BUILD" != "1" ]]; then
  echo "Building frontend..."
  (cd apps/dsa-web && npm ci && npm run lint && npm run build)
fi

echo "Creating server backup..."
backup_name="daily-stock-analysis-$(date +%Y%m%d-%H%M%S).tgz"
run_remote "set -e
mkdir -p '$DSA_BACKUP_DIR'
tar --exclude='$DSA_SERVER_PATH/venv' \
    --exclude='$DSA_SERVER_PATH/.venv' \
    --exclude='$DSA_SERVER_PATH/apps/dsa-web/node_modules' \
    -czf '$DSA_BACKUP_DIR/$backup_name' \
    -C '$(dirname "$DSA_SERVER_PATH")' '$(basename "$DSA_SERVER_PATH")'
ls -lh '$DSA_BACKUP_DIR/$backup_name'"

echo "Syncing source and static assets..."
rsync -az --delete \
  --exclude='.git/' \
  --exclude='/.env' \
  --exclude='/data/' \
  --exclude='/reports/' \
  --exclude='/logs/' \
  --exclude='/venv/' \
  --exclude='/.venv/' \
  --exclude='/apps/dsa-web/node_modules/' \
  --exclude='__pycache__/' \
  --exclude='*.pyc' \
  -e "${rsync_ssh[*]}" \
  "$ROOT_DIR/" "$remote:$DSA_SERVER_PATH/"

echo "Installing server dependencies and runtime SQLite shim..."
run_remote "set -e
cd '$DSA_SERVER_PATH'
cat >/tmp/dsa-constraints.txt <<'EOF'
numpy==1.26.4
pandas==2.2.3
Pillow==10.4.0
greenlet==3.0.3
Cython<3.2
EOF
./venv/bin/pip install -c /tmp/dsa-constraints.txt -r requirements.txt
./venv/bin/pip install pysqlite3-binary
sitepkg=\$(./venv/bin/python - <<'PY'
import site
print(site.getsitepackages()[0])
PY
)
cat > \"\$sitepkg/sitecustomize.py\" <<'PY'
\"\"\"Prefer pysqlite3-binary so SQLAlchemy sees a modern SQLite build.\"\"\"
import sys
try:
    import pysqlite3
except Exception:
    pass
else:
    sys.modules[\"sqlite3\"] = pysqlite3
PY
if grep -q '^ALPHASIFT_ENABLED=true' .env && ! grep -q '^SCREENING_ENABLED=' .env; then
  cp .env \".env.bak-screening-\$(date +%Y%m%d-%H%M%S)\"
  printf '\\nSCREENING_ENABLED=true\\n' >> .env
fi
PYTHONPYCACHEPREFIX=/tmp/dsa-pycache ./venv/bin/python -m py_compile \
  main.py \
  server.py \
  api/app.py \
  api/v1/endpoints/analysis.py \
  api/v1/endpoints/screening.py \
  api/v1/schemas/portfolio.py \
  src/config.py \
  src/storage.py \
  src/services/portfolio_risk_service.py \
  src/services/portfolio_service.py \
  src/services/screening_service.py
./venv/bin/python - <<'PY'
import sqlite3
from src.config import get_config
from src.storage import DatabaseManager
conn = sqlite3.connect(':memory:')
conn.create_function('x', 1, lambda x: x, deterministic=True)
cfg = get_config()
print('sqlite', sqlite3.__name__, sqlite3.sqlite_version)
print('screening', getattr(cfg, 'screening_enabled', None))
print('model', getattr(cfg, 'litellm_model', None))
DatabaseManager()
print('db ok')
PY"

echo "Restarting service..."
run_remote "systemctl restart '$DSA_SERVICE_NAME' && systemctl is-active '$DSA_SERVICE_NAME'"

echo "Checking health..."
health_ok=0
for attempt in {1..30}; do
  if curl -fsS -k "$DSA_HEALTH_URL"; then
    health_ok=1
    break
  fi
  echo "Health check not ready yet (attempt $attempt/30); retrying in 3s..."
  sleep 3
done
if [[ "$health_ok" != "1" ]]; then
  echo "Health check failed after waiting." >&2
  exit 1
fi
echo
echo "Deployment finished. Backup: $DSA_BACKUP_DIR/$backup_name"
