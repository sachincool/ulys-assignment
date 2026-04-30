# manifests/

Kustomize tree applied by CI after Terraform creates the cluster.

## Layout

```
base/                 fixed resources w/ ${VAR} placeholders for env-specific values
overlays/dev/         per-env kustomization, image tags updated by CI
```

## How CI applies it

1. Read Terraform outputs from `infra/envs/dev` (LB IP, GSA emails, DB IP, Redis addr).
2. Export them as env vars.
3. `kustomize edit set image ulys/api=$API_IMAGE ulys/worker=$WORKER_IMAGE` in `overlays/dev/`.
4. `kustomize build overlays/dev | envsubst | kubectl apply -f -`.

The `envsubst` step replaces `${API_LB_STATIC_IP}`, `${API_GSA_EMAIL}`,
`${WORKER_GSA_EMAIL}`, `${PROJECT_ID}`, `${DB_HOST}`, `${REDIS_ADDR}`.

## Canary

The api `Rollout` runs:

- 10% canary → 30s soak → AnalysisRun on `/readyz` (3 probes, 10s apart, fail-fast)
- 50% → 30s soak → AnalysisRun
- 100%

On any AnalysisRun failure, traffic stays on the prior stable revision and
the Rollout enters `Degraded`. CI watches with `kubectl argo rollouts status`
and fails the job, leaving the cluster on the last known-good revision.

## Worker auth

`/transform` requires `Authorization: Bearer <jwt>` where the JWT is a
Google ID token whose `aud` matches `WORKER_AUDIENCE` and whose `email`
claim equals `API_SA_EMAIL` (the api's GSA). The api fetches this token
from the GKE metadata server via Workload Identity (no shared secret to
mount, sync, or rotate). NetworkPolicy is the second layer.

## Web → API

`api-public` is a `LoadBalancer` Service pinned to the static external
IP Terraform reserves (`api-lb`). The web bucket's `index.html` has its
`__API_URL__` placeholder replaced with `http://<that-IP>` by CI.
