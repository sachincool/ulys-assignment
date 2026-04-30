# Visual walk-through

What this stack looks like once `just up ENV=dev …` completes.

Companion to the project [`README.md`](../README.md). **Reviewers — start
at the README's [§ For reviewers — read me first](../README.md#for-reviewers--read-me-first).**
That section pre-empts the questions a careful review would otherwise
ask (cost, blast-radius math, mixed-content, intentional caveats) and
points to the exact files. This file is the picture-walk after.

---

## 1 · Source layout

One repo. App code, Terraform, manifests, CI all live together —
single-repo Kustomize + `kubectl apply -k` is the documented pattern
for a one-team, one-product setup. The split-repo + Argo CD upgrade
is documented in the README's "What's deferred for production".

```
apps/                  Go (api + worker) + static web
infra/                 Terraform (HCL) — bootstrap + envs/dev
manifests/             Kustomize — base + overlays/dev
.github/workflows/     ci-app + ci-infra
```

---

## 2 · CI/CD

`ci-infra.yml` runs on PRs (`terraform fmt -check && terraform validate
&& terraform plan` posted as a PR comment) and on merge to `main`
(`terraform apply`).

`ci-app.yml` runs on PRs (`go vet && go test && kustomize build |
kubectl apply --dry-run`) and on merge to `main`:

1. Matrix-build api + worker, push to Artifact Registry.
2. Read Terraform outputs from the GCS state bucket.
3. `kustomize edit set image` + `kustomize build | envsubst |
   kubectl apply -f -`.
4. `kubectl argo rollouts status api -n ulys --timeout 10m` — exits
   non-zero on Aborted/Degraded; CI fails the job, traffic stays on
   the prior stable revision.
5. On success, smoke `/readyz` ten times against the public LB.
6. `deploy-web` (parallel-after-deploy): rsync `apps/web` → GCS
   bucket with `__API_URL__` substituted.

---

## 3 · GCP project

`ulys-dev-XXXXX` owns every dev resource. `just down` returns it to $0.

### GKE Autopilot cluster

- Zonal control plane (free first cluster per project)
- Private nodes
- Workload Identity (no JSON keys, ever)
- NetworkPolicy enforcement via Dataplane V2 (Cilium)
- Shielded Nodes, image streaming, Pod Security Standards `restricted`
  applied at the namespace boundary

### Cloud SQL Postgres

`db-f1-micro`, private IP only. Reachable from the cluster via the
VPC's private services access; no public surface. The api connects
with the password from Secret Manager, mounted as a file via the
GKE-managed Secret Manager CSI add-on (read at startup from
`$DB_PASSWORD_FILE = /var/run/secrets/gsm/db-password`).

### Memorystore Redis

`BASIC` tier, 1 GiB, private IP. Prod upgrades to `STANDARD_HA` with
AUTH + transit encryption — see README.

### Workload Identity Federation

GitHub Actions assumes the deployer GSA via OIDC. The provider's
`attribute_condition` pins trust to one repository AND one GitHub
Environment (`assertion.repository == "owner/repo" &&
assertion.environment == "dev"`).

### Service accounts (curated, no Owner on runtime)

- `gh-deployer-dev` — what GitHub Actions impersonates. Curated roles
  (artifactregistry.admin, container.admin, run.admin, cloudsql.admin,
  redis.admin, secretmanager.admin, storage.admin, …) — **no Owner**.
- `ulys-api` — runtime GSA the api KSA impersonates.
  `roles/cloudsql.client`, `roles/secretmanager.secretAccessor`
  (scoped to db-app-password).
- `ulys-worker` — runtime GSA the worker KSA impersonates. No project
  roles beyond logging/tracing/metrics writers.

### Artifact Registry

`api:<sha>` and `worker:<sha>` from every successful pipeline run.

### Secret Manager

`db-app-password` is the only runtime secret. The GKE-managed Secrets
Store CSI add-on mounts it into the api Pod as a file at
`/var/run/secrets/gsm/db-password` via `SecretProviderClass: api-gsm`
(`provider: gke`, driver `secrets-store-gke.csi.k8s.io`). The api
reads `$DB_PASSWORD_FILE` at startup. No K8s Secret round-trip — the
managed driver KSA isn't granted cluster-wide `secrets.list/watch`
on Autopilot, so the upstream `secretObjects` sync mode doesn't work
there anyway, and file-mount is the cleaner pattern (same shape as
Cloud Run secret injection / Vault Agent). **No cleartext password
in TF state, in git, or anywhere on disk in the repo.**

---

## 4 · Forcing function — how to reproduce

The cleanest forcing function is a **manifest-only** change that
redirects `DB_PASSWORD_FILE` in the dev overlay at a wrong-content
file. `/etc/hostname` exists in the distroless container image and
contains the pod hostname (not a valid postgres password), so the
api boots fine, `/livez` returns 200, but `/readyz` calls into the
db pool — connection auth fails — `/readyz` returns 503. No app
code mutates, the diff is one line, revert is `git revert`.

```yaml
# manifests/overlays/dev/kustomization.yaml — append:

patches:
  - target: { kind: Rollout, name: api }
    patch: |-
      - op: replace
        path: /spec/template/spec/containers/0/env/5/value
        value: "/etc/hostname"
```

(Index `5` is `DB_PASSWORD_FILE` in `manifests/base/api-rollout.yaml`'s
`env:` list — verify the index before applying.)

```bash
# After the green initial deploy:
#
# 1. Apply the patch above to manifests/overlays/dev/kustomization.yaml.
# 2. git commit + push to main.
#
# CI builds the (unchanged) image, kustomize-edits the Rollout, applies.
# Argo Rollouts creates a canary ReplicaSet at setWeight: 10 — which
# with replicas: 2 means 1 canary pod. Kube-proxy round-robins the
# api-canary Service to the one canary pod, so smoke traffic hits
# the broken revision until the analysis trips. The AnalysisTemplate
# spawns a curl Job hitting /readyz on api-canary; /readyz pings DB,
# DB auth fails (the password is now the literal pod hostname),
# /readyz returns 503, the Job exits 1, the AnalysisRun is marked
# Failed (failed > failureLimit). Rollout enters Degraded, scales
# the canary ReplicaSet to 0, routes 100% of traffic back to the
# stable revision.
#
# Public traffic exposure to the bad revision is bounded by canary
# weight × analysis time (~10% × 30–70s before the AnalysisRun trips).
# api-public always has at least one stable pod in its endpoints.
#
# To recover: git revert the kustomization commit, push, the next
# CI run promotes a green revision via the same canary path.
```

The runs in the [Submission table](../README.md#submission) link to
the exact GH Actions runs that demonstrated this on the live cluster.

---

## 5 · Tear-down

```bash
just down ENV=dev PROJECT_ID=ulys-dev-XXXXX
```

What it does, in order:

1. `terraform destroy` on `infra/envs/dev` — drops cluster, DB,
   cache, IAM, secrets, web bucket, budget, uptime check, static IP.
2. `terraform destroy` on `infra/bootstrap` — drops state bucket,
   WIF pool, deployer SA.
3. `gcloud projects delete` — billing stops immediately, project
   shell sticks around 30 days for restore.

The full `terraform destroy` log lives in
[`destroy.txt`](destroy.txt).
