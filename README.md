# ulys-assignment

A small three-service system on **GCP**, built **production-ready**:
**GKE Standard** (private, opinionated) provisioned with **Pulumi (TypeScript)**,
deployed via **Argo CD GitOps** + **Argo Rollouts** progressive delivery,
secrets via **External Secrets Operator** and Google Secret Manager.

```
                              ┌───────────────────────┐
   client ───────────────────▶│ External HTTPS LB     │
                              │ + Cloud Armor*        │   *production add-on
                              └───────────┬───────────┘
                                          │
                              ┌───────────▼──────────┐
                              │ GKE Standard zonal   │
                              │ (private nodes)      │
                              │                      │
                              │ ┌──────────┐ ┌───────│
                              │ │ api      │─│worker │   in-cluster, NetworkPolicy
                              │ │ Rollout  │ │Roll'  │   gates worker ingress to
                              │ └────┬─────┘ └───────│   pods labeled `app=api`
                              │      │ Workload      │
                              │      │ Identity      │
                              └──────┼───────────────┘
                                     │
                              ┌──────▼─────────┐
                              │ Cloud SQL      │ (private IP)
                              │ Memorystore    │ (private IP)
                              │ Secret Manager │ (via ESO)
                              └────────────────┘
```

App code total: ~200 lines.

---

## Submission

| | |
|---|---|
| 🟢 First green canary deploy | [ci-app run](https://github.com/sachincool/ulys-prod/actions/runs/25154644140) — both images built + signed, manifest digest committed |
| 🔴 Forcing-function rollback | [ci-app run](https://github.com/sachincool/ulys-prod/actions/runs/25157193906) (broken `/readyz`) — broken image built; Argo Rollouts canary RS could not become Ready, traffic stayed on the stable revision, eventually marked `Degraded` with `ProgressDeadlineExceeded`. **Public traffic exposure to the bad revision: zero.** |
| ✅ Green re-deploy after revert | [ci-app run](https://github.com/sachincool/ulys-prod/actions/runs/25158353537) — fixed image built; Argo Rollouts canary smoke passes; promoted to 100% |
| 📜 `pulumi destroy` output | [`docs/destroy.txt`](docs/destroy.txt) |
| 🧾 Billing screenshot | [`docs/billing.png`](docs/billing.png) |
| 🖼️ Visual walk-through | [`docs/SETUP_DOCS.md`](docs/SETUP_DOCS.md) |
| 🌐 Live api (when up) | `http://136.115.83.214` — `/livez /healthz /readyz /version /work` |

---

## Plug-and-play setup (one command per direction)

```bash
# Pre-reqs (one-time): brew install pulumi pnpm gcloud kubectl helm gh
# gcloud auth login && gcloud auth application-default login

# Spin up a fresh dev environment from a clean GCP account:
make up \
  ENV=dev \
  PROJECT_ID=ulys-dev-XXXXX \
  BILLING_ACCOUNT=01XXXX-XXXXXX-XXXXXX

# What this does:
#   1. gcloud projects create + billing link + enable 17 APIs
#   2. infra/bootstrap pulumi up: state bucket + WIF pool + curated deployer SA
#   3. infra/stacks/dev pulumi up: VPC + GKE Standard + Cloud SQL + Memorystore
#      + Artifact Registry + Secret Manager + IAM
#   4. kubectl apply Argo CD root Application pointing at the manifests repo
#   5. Wait for apps-dev to reach Healthy

# Tear it all back down:
make down ENV=dev PROJECT_ID=ulys-dev-XXXXX
```

After `make up` finishes, every subsequent change goes through GitOps:
push to `main` → CI builds + signs → CI opens a manifest-bump PR →
merge → Argo CD reconciles → Argo Rollouts does the canary.

---

## Architecture decisions

- **GKE Standard, not Autopilot.** Free zonal control plane + the same best
  practices applied explicitly (private cluster, Workload Identity,
  NetworkPolicy enforcement via Calico, shielded nodes, release channel
  REGULAR, auto-repair/upgrade). Autopilot is correct for multi-team
  platforms; this is a one-team-one-product setup. Cost is roughly half.
- **Single zonal cluster.** Cluster `location: us-central1-a`. Free control
  plane, single zone for nodes. Multi-region is a 2-line upgrade
  (`location: zone` → `location: region` and stamp the stack a second time
  in another region).
- **Argo Rollouts over Flagger.** Argo Rollouts is the sister project to
  Argo CD, doesn't need a service mesh, has a UI, integrates natively
  with the GitOps flow. AnalysisTemplate runs a Job (curl-based smoke)
  that's exactly the take-home's `scripts/smoke.sh` translated to K8s native.
- **Pulumi (TypeScript), not Terraform.** Real types catch typos at compile
  time; real refactoring lets components stay DRY across `infra/stacks/{dev,
  staging,prod}`. State lives in a GCS bucket per env; locking is built in.
- **External Secrets Operator + Google Secret Manager.** App code reads
  `DB_PASSWORD` as a regular env var; ESO syncs it from Secret Manager via
  Workload Identity. Cleartext never lives in TF state, never on disk in
  the repo.
- **Workload Identity, no JSON keys.** GitHub Actions assumes the deployer
  GSA via WIF (`attribute_condition` pins it to one repo + one GH
  Environment). Runtime pods impersonate their own GSAs via KSA → GSA
  binding. No service account JSON anywhere.
- **NetworkPolicy** is shipped (worker ingress is restricted to pods
  labeled `app=api`) — though the take-home variant relaxes the
  default-deny that fought DNS resolution; production would re-enable it
  with explicit DNS egress rules.
- **`runAsNonRoot: true` + numeric `runAsUser: 65532`.** distroless's
  `nonroot` user is named, not numeric, and PSA `restricted` rejects
  named-user images. Pinning to the well-known UID 65532 satisfies the
  policy.

---

## Estimated monthly cost (us-central1, idle, dev)

| | $/mo |
|---|---|
| GKE Standard zonal control plane | $0 (first zonal cluster per project is free) |
| 2× e2-standard-2 nodes (cluster autoscaler, spot) | ~$30 |
| Cloud SQL `db-f1-micro` Postgres + 10 GiB SSD | ~$9 |
| Memorystore Redis BASIC, 1 GiB | ~$35 |
| Cloud NAT, LBs, Cloud Logging, egress | ~$8 |
| **Total dev idle** | **~$80-90/mo** |

Production-default (regional control plane + HA Cloud SQL + STANDARD_HA
Memorystore + Cloud Armor) lands around $250-300/mo. `pulumi destroy`
returns to $0.

A `$300` Cloud Billing budget with 50/90/100% email alerts is in
`infra/stacks/prod/index.ts` (commented-out for dev).

---

## Adding a second environment

3 GCP projects, same Pulumi stack pattern, image-digest promotion:

```
infra/stacks/{dev,staging,prod}/index.ts   # one stack file per env
manifests/apps/{dev,staging,prod}/         # one overlay per env
.github/workflows/promote.yml              # manual workflow_dispatch:
                                           #   from: dev → staging → prod
                                           # (copies signed digest forward)
```

`prod` lives in a GitHub Environment with a manual approver gate.
Promotion is by image digest, never by `:latest` tag flip.

---

## What's deferred for production

- **Linkerd / Istio service mesh** for mTLS + traffic-split-based canaries
  driven by Prometheus SLO metrics. Argo Rollouts handles the canary today
  via Job-based AnalysisTemplate; mesh-driven traffic split is the next-tier
  upgrade.
- **Cloud Armor + global HTTPS LB + custom domain + managed cert.**
  Currently exposed via L4 LoadBalancer Service.
- **Cloud SQL HA + PITR + IAM auth via the Auth Proxy.** Currently the api
  uses plain DSN with the password from Secret Manager. Switching to IAM
  auth requires creating the Postgres user with
  `--type=cloud_iam_service_account`.
- **Atlas migrations** as a pre-sync Argo CD hook. Currently the api does
  `CREATE TABLE IF NOT EXISTS hits` on boot.
- **OpenTelemetry collector + structured tracing.** App is wired with the
  OTel SDK (gated on `OTEL_ENABLE=true`); no collector deployed for the
  take-home — Cloud Logging picks up stdout natively.
- **Re-enable default-deny NetworkPolicy** with explicit DNS allow,
  validated end-to-end before turning enforcement on.
- **Image signing enforcement** via Binary Authorization + cosign. CI
  signs images today; BinAuthz is wired in `infra/components/binauthz.ts`
  for staging/prod stacks but not enforced on dev.

---

## Layout

```
apps/
  api/      cmd/api, internal/{db,server,telemetry}     Go: chi + slog + graceful shutdown
  worker/   cmd/worker, internal/server                  Go: net/http + otelhttp
infra/                                                   Pulumi (TypeScript)
  bootstrap/    one-shot: state bucket + WIF + deployer SA
  components/   gke / postgres / memorystore / secrets / wi / binauthz
  stacks/       dev / staging / prod
.github/workflows/
  ci-app.yml    test → matrix-build → cosign sign → manifest-bump PR
  ci-infra.yml  pulumi preview on PR; pulumi up on merge per env
  promote.yml   manual: copy signed digest from one env to the next
Makefile        make up / make down

# Manifests live in a separate repo (GitOps best practice):
#   github.com/sachincool/ulys-manifests
```

---

## References

- [Pulumi Workload Identity for GKE](https://www.pulumi.com/registry/packages/gcp/api-docs/container/cluster/)
- [Argo Rollouts Canary with AnalysisTemplate](https://argo-rollouts.readthedocs.io/en/stable/features/canary/)
- [External Secrets Operator: GCPSM provider](https://external-secrets.io/latest/provider/google-secrets-manager/)
- [Workload Identity Federation for GitHub Actions](https://github.com/google-github-actions/auth)
