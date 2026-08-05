# Jianqin Local Overrides

This directory stores local patches that are intentionally kept outside the
upstream project history.

## Patch

- `jianqin-local-overrides.patch`

Current contents:

- FastAPI port probe uses `SO_REUSEADDR` for smoother systemd restarts.
- Portfolio risk sector lookup uses concurrent resolution and a 24-hour
  in-process cache.
- Portfolio snapshot exposes a local-only `name` field for positions, and the
  Web portfolio table displays name plus code without calling external name
  providers during the snapshot request.

## Reapply After Pulling Upstream

From the repository root:

```bash
git fetch --tags origin
git stash push -m before-upstream-upgrade -- .
git pull --ff-only
git apply --3way scripts/patches/jianqin-local-overrides.patch
```

Then run local validation and deploy:

```bash
PYTHONPYCACHEPREFIX=/tmp/dsa-pycache ./.venv/bin/python -m py_compile \
  main.py api/v1/schemas/portfolio.py src/services/portfolio_service.py src/services/portfolio_risk_service.py

cd apps/dsa-web
npm ci
npm run lint
npm run build
cd ../..

DSA_SSH_PASS='your-server-password' DSA_SKIP_PULL=1 ./scripts/deploy_aliyun_upgrade.sh
```

## Refresh This Patch

After changing the local overrides, regenerate the patch from the repository
root:

```bash
git diff -- \
  main.py \
  src/services/portfolio_risk_service.py \
  src/services/portfolio_service.py \
  api/v1/schemas/portfolio.py \
  apps/dsa-web/src/pages/PortfolioPage.tsx \
  apps/dsa-web/src/types/portfolio.ts \
  apps/dsa-web/src/locales/featureText.ts \
  apps/dsa-web/src/pages/__tests__/PortfolioPage.test.tsx \
  > scripts/patches/jianqin-local-overrides.patch
```

Do not put server passwords or API keys in patch files.
