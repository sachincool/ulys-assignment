# ulys-assignment

A small three-service system on **GCP**, fully provisioned with **Terraform**,
shipped via **GitHub Actions**, running on **GKE Autopilot** with a real
weight-split canary (Argo Rollouts) and automatic rollback gated on
`/readyz` analysis.

```
   browser ────▶ web (static GCS bucket, public)
                  │
                  ▼  fetch ${API_URL}/work
                       ┌────────────────────────┐
                       │ static external IP     │  ← reserved by Terraform
                       │ (Cloud Monitoring      │     (api-lb)
                       │  uptime check + alert) │
                       └───────────┬────────────┘
                                   │
                       ┌───────────▼──────────┐
                       │ GKE Autopilot zonal  │
                       │ (private nodes)      │
                       │                      │
                       │ ┌──────────┐ Bearer  │
                       │ │ Rollout  │ Google  │
                       │ │ /api     │ ID JWT  │
                       │ │ canary   │ ──────▶ │ Deployment/worker
                       │ └────┬─────┘ (aud +  │ (validates JWT;
                       │      │  WI)          │  401 on miss)
                       └──────┼───────────────┘
                              │
                       ┌──────▼─────────┐
                       │ Cloud SQL      │ (private IP, PSA)
                       │ Memorystore    │ (private IP, PSA)
                       │ Secret Manager │ (via GSM CSI driver)
                       └────────────────┘
```

App code: ~530 LOC of Go (handlers ~120, api `main.go` ~160, worker
`main.go` ~120, db helper ~50, OTel init ~60) + ~75 LOC of HTML/JS.
The brief's "<200 LOC" target is for the trivial handler code; the
chi + pgx + redis + slog + graceful-shutdown + WI ID-token boilerplate
spends another ~300 LOC that pays for itself the first time the
service hits SIGTERM during a rollout.

---

## For reviewers — read me first

Land here, then jump where you want. Five minutes of context that
pre-empts the questions a careful review would otherwise ask.

### What to look at, in priority order

1. **The canary + forcing function (the whole point of the brief).**
   - Rollout spec: [`manifests/base/api-rollout.yaml`](manifests/base/api-rollout.yaml) — 10 → 50 → 100 weighted steps, `pause` + `analysis` between each, `AnalysisTemplate` ref.
   - Probe: [`manifests/base/analysistemplate.yaml`](manifests/base/analysistemplate.yaml) — Job spawns `curlimages/curl`, hits `/readyz`, exits non-zero on a non-200.
   - Reproduction recipe: [`docs/SETUP_DOCS.md` § 4 · Forcing function](docs/SETUP_DOCS.md#4--forcing-function--how-to-reproduce). Patch overrides `DB_PASSWORD` in the dev overlay → `/readyz` returns 503 → AnalysisRun fails → Rollout aborts → stable revision keeps serving.
   - CI gating: [`.github/workflows/ci-app.yml`](.github/workflows/ci-app.yml) — `kubectl argo rollouts status api -n ulys --timeout 10m` exits non-zero on Aborted/Degraded; the workflow then explicitly aborts (belt + suspenders) and `exit 1`s.
2. **Auth chain.** Three layers, each in one obvious file:
   - GH Actions → GCP: WIF pool/provider in [`infra/bootstrap/main.tf`](infra/bootstrap/main.tf), pinned to **repo + GH Environment** by `attribute_condition`.
   - Pod → GCP: KSA → GSA annotation in [`manifests/base/serviceaccounts.yaml`](manifests/base/serviceaccounts.yaml); `workloadIdentityUser` IAM binding in [`infra/envs/dev/runtime.tf`](infra/envs/dev/runtime.tf).
   - api → worker: `idtoken.NewClient` in [`apps/api/internal/server/handlers.go`](apps/api/internal/server/handlers.go); JWT validation (sig + iss + aud + email + email_verified) in [`apps/worker/cmd/worker/main.go`](apps/worker/cmd/worker/main.go) — ~30 LOC.
3. **Defense in depth on api → worker.** [`manifests/base/networkpolicy.yaml`](manifests/base/networkpolicy.yaml) — only `app=api` pods can reach `app=worker:8080`. Enforced by GKE Autopilot's Dataplane V2 (Cilium).
4. **Pod Security restricted at the namespace boundary.** [`manifests/base/namespace.yaml`](manifests/base/namespace.yaml) sets `enforce/audit/warn=restricted`. Every pod in `ulys` (api, worker, **and** the AnalysisTemplate probe Job) carries a hardened `securityContext`.

### Known caveats — intentional, surfaced here so they don't read as bugs

| Caveat | Why it's like this | Where to fix it |
|---|---|---|
| **Idle cost lands ~$135/mo, not the brief's $5–15.** | Autopilot's $73/mo cluster fee + Memorystore BASIC's $35/mo floor are unavoidable on this shape. See [Estimated monthly cost](#estimated-monthly-cost-us-central1-idle-dev) for the line-by-line. | $5–15 only fits a serverless shape (Cloud Run + auto-pause SQL + no Redis). `just down` returns to $0 in seconds. |
| **`$20` budget alert fires day 1.** | Deliberate tripwire — proves the alert path works end-to-end on first stand-up. | Bump `var.budget_amount` to `15000` (~$150) for a non-tripping ceiling. |
| **Canary blast radius is ~33–50% of traffic, not 10%.** | Argo Rollouts without a TrafficRouter splits by **pod count**; with `replicas: 2` and `setWeight: 10`, you get 1 canary pod = 1/3 of pods (during surge) ≈ kube-proxy RR. The brief's spirit (bounded blast radius, fast auto-rollback) is intact; the precise number is honest. | Add NGINX Ingress / Linkerd as the `trafficRouting` provider, or bump `replicas` to 10. Listed in [What's deferred](#whats-deferred-for-production). |
| **Web → API hits HTTP from an HTTPS page → mixed-content block.** | GCS serves `https://`, the api LB is L4 `http://`. Modern browsers refuse the cross-scheme `fetch`. | Open the page from `http://storage.googleapis.com/...` (GCS serves both schemes), or open `apps/web/index.html` over `file://`. The prod upgrade — global HTTPS LB + custom domain + managed cert — dissolves this. |
| **Cluster is zonal (`us-central1-a`).** | `var.zone` default. Same $73/mo control-plane fee as regional but single-AZ blast radius — appropriate for dev. | Flip `location = var.region` for regional HA in prod. Documented in [Architecture decisions](#architecture-decisions) and the prod-comparison table. |
| **Dev master_authorized_networks is `0.0.0.0/0`.** | Take-home convenience so a reviewer can `kubectl` from anywhere. | Tightened to `<CI runner CIDR>` + bastion in prod ([prod-comparison table](#adding-a-production-environment-described-not-built)). |
| **App is ~530 LOC, brief said <200.** | The brief's <200 is for the trivial handler code; the chi + pgx + redis + slog + graceful-shutdown + WI ID-token boilerplate is the other ~300 and pays for itself first SIGTERM. OTel SDK is gated on `OTEL_ENABLE=true` — no collector, so it costs zero runtime but adds LOC. | If LOC matters more than ergonomics, drop `apps/api/internal/telemetry` + the chi middleware (~60 LOC). |

### How to read CI runs

The submission table links three ci-app runs:

- **🟢 first green canary** → look for `Watch Rollout to completion (gate on Healthy)` succeeding and the `Smoke /readyz on public LB ×10` step printing 10 × 200s.
- **🔴 forcing-function rollback** → look for `Watch Rollout` exiting non-zero with the AnalysisRun's curl-Job logs visible. The rollout's `Aborted` status is the success criterion of *this* run, not a failure to investigate. CI fails on purpose so the bad image never gets promoted.
- **✅ green re-deploy** → same shape as the first run, on the revert commit.

### What I'd change if I had another day

In rough priority: NGINX Ingress for true L7 weighted split (tightens caveat #3); a Prometheus AnalysisTemplate replacing the curl-Job probe (richer signal than 200/non-200); BinAuthz + cosign-keyless on every digest (would catch a tampered image at admission time); tighten `master_authorized_networks` to a known CIDR even in dev.

### Where it isn't this stack's problem

The brief's `~$5–15/mo` target is a serverless target. On any GKE (Autopilot or Standard), the cluster fee + Memorystore floor put the realistic floor ~$110/mo. Either accept the $135 number for the GKE shape, or move to Cloud Run + Cloud SQL `auto-pause` + drop Memorystore — that's a different submission with different trade-offs around in-cluster control-plane composability (NetworkPolicy, ServiceMesh, GitOps) which is what GKE buys.

---

## Submission

| | |
|---|---|
| 🟢 First green canary deploy | [ci-app run](https://github.com/sachincool/ulys-assignment/actions/runs/REPLACE_ME) — image built, Argo Rollouts walked 10 → 50 → 100 with `/readyz` AnalysisRuns green at every step |
| 🔴 Forcing-function rollback | [ci-app run](https://github.com/sachincool/ulys-assignment/actions/runs/REPLACE_ME) — broken `/readyz` (intentionally bad DB password via dev overlay) → AnalysisRun `Failed` at the first probe step → Rollout `Aborted` → traffic stays 100% on prior stable revision → CI fails. **Public traffic exposure to the bad revision: one of two pods (~33–50% by kube-proxy round-robin) for ~30–70s** — Argo Rollouts without a TrafficRouter splits by ReplicaSet pod count, not HTTP weight, so `setWeight: 10` with `replicas: 2` lands at one canary pod, not 10% of requests. The brief's spirit (bounded blast radius, fast auto-rollback) is preserved; precise weighted L7 split needs a mesh or NGINX Ingress (see [What's deferred](#whats-deferred-for-production)). |
| ✅ Green re-deploy after revert | [ci-app run](https://github.com/sachincool/ulys-assignment/actions/runs/REPLACE_ME) — fixed image, Rollout reaches Healthy |
| 📜 `terraform destroy` output | [`docs/destroy.txt`](docs/destroy.txt) |
| 🧾 Billing screenshot | [`docs/billing.png`](docs/billing.png) |
| 🖼️ Visual walk-through | [`docs/SETUP_DOCS.md`](docs/SETUP_DOCS.md) |
| 🌐 Live api (when up) | `http://<api_lb_static_ip>` (`terraform output -raw api_lb_static_ip`) — `/livez /healthz /readyz /version /work` |
| 🌐 Live web (when up) | `https://storage.googleapis.com/<PROJECT_ID>-web/index.html` |

---

## Plug-and-play setup (one command per direction)

```bash
# Pre-reqs (one-time): brew install just terraform gcloud kubectl helm gh kustomize
# gcloud auth login && gcloud auth application-default login

just up \
  ENV=dev \
  PROJECT_ID=ulys-dev-XXXXX \
  BILLING_ACCOUNT=01XXXX-XXXXXX-XXXXXX

# What this does:
#   1. gcloud projects create + billing link + bootstrap-required APIs
#   2. infra/bootstrap terraform apply: state bucket + WIF pool + curated deployer SA
#   3. infra/envs/dev terraform apply: VPC + GKE Autopilot + Cloud SQL +
#      Memorystore + Artifact Registry + Secret Manager + IAM + budget +
#      uptime check + static api LB IP
#   4. helm install argo-rollouts + secrets-store-csi-driver + GCP provider
#   5. kustomize build manifests/overlays/dev | envsubst | kubectl apply
#   6. wait until Rollout/api is Healthy

# Tear it all back down (returns to $0):
just down ENV=dev PROJECT_ID=ulys-dev-XXXXX
```

After `just up` finishes, every subsequent change goes through CI:

- **`infra/**` change** → `ci-infra.yml` runs `terraform fmt + validate + plan`
  on PR (plan posted as a comment) → `terraform apply` on merge to `main`.
  State lives in the GCS bucket `infra/bootstrap/` provisions.
- **`apps/**` or `manifests/**` change** → `ci-app.yml` runs `go vet` +
  `go test` + `kustomize build | kubectl --dry-run` on PR → on merge:
  builds images, pushes to Artifact Registry, reads Terraform outputs
  for the per-env values, `kustomize edit set image` to bump tags,
  `kustomize build | envsubst | kubectl apply -f -`. Argo Rollouts
  detects the spec change, runs the canary, CI gates on
  `kubectl argo rollouts status api`.

CI authenticates to GCP via **Workload Identity Federation — no long-lived
keys**. The deployer GSA has a curated role set with no Owner.

---

## Web → API communication

`web` is one static `index.html` shipped to a public GCS bucket
(`<PROJECT_ID>-web`). On click, it `fetch`es `${API_URL}/work`, where
`API_URL` is replaced at deploy time by `ci-app.yml`'s `deploy-web` job
with `http://<api_lb_static_ip>` (the static IP reserved by Terraform).

> **Mixed-content caveat (dev only).** GCS bucket URLs serve over
> `https://`, but `Service/api-public` is plain L4 `http://`. Modern
> browsers block HTTPS pages from `fetch`ing HTTP origins. To exercise
> the demo end-to-end, either (a) open the page from the bucket's
> `http://storage.googleapis.com/...` endpoint (works because GCS
> serves both schemes), or (b) clone the repo and open
> `apps/web/index.html` over `file://` for local testing. The prod
> upgrade — global HTTPS LB + custom domain + managed cert — lives in
> [What's deferred](#whats-deferred-for-production) and dissolves this
> caveat entirely.

Why this pattern:

- **$0/mo for the bucket itself.** A public GCS bucket plus a single L4
  `Service: LoadBalancer` is the cheapest exposed-to-the-internet pair on
  GCP. Cloud CDN + GCLB + a managed cert is the prod upgrade — listed
  in [What's deferred](#whats-deferred-for-production).
- **Zero CORS surprise.** Bucket has explicit
  `cors: [{ origins: ["*"], methods: ["GET"] }]`; the api adds
  `Access-Control-Allow-Origin: *`. No preflight.
- **Stable API URL across pod cycles.** `Service/api-public` pins to
  `loadBalancerIP: ${api_lb_static_ip}`, so the static HTML in the
  bucket doesn't need re-stamping when pods cycle.

---

## api → worker authentication

The brief explicitly requires `worker` to **reject unauthenticated
traffic from anywhere except the api**. Defense is layered, both layers
shipped:

1. **NetworkPolicy** (`manifests/base/networkpolicy.yaml`):
   only pods labeled `app=api` can connect to pods labeled `app=worker`
   on port 8080. Blocks lateral movement from any other pod that lands
   on a compromised node. GKE Autopilot uses Dataplane V2 (Cilium) for
   NetworkPolicy enforcement.
2. **Google ID token** validated by the worker against Google's JWKs.
   Every api → worker request carries `Authorization: Bearer <jwt>`
   where the JWT is fetched by the api's pod from the GKE metadata
   server with `audience=http://worker.ulys.svc.cluster.local`. The
   worker validates:
   - signature (against Google JWKs, refreshed on cache miss)
   - expiry, issuer
   - `aud` claim equals `WORKER_AUDIENCE` env (the worker URL)
   - `email` claim equals `API_SA_EMAIL` env (the api's GSA email)
   - `email_verified` is true

   See `apps/worker/cmd/worker/main.go::requireGoogleIDToken` and
   `apps/api/internal/server/handlers.go::callWorker`.

Why ID tokens, not HMAC or mTLS:

- **Zero shared secret.** Nothing to provision in Secret Manager,
  nothing to mount, nothing to rotate, nothing to leak. The auth
  signal is the api's GSA — the same identity it already uses for
  Cloud SQL, Secret Manager, etc.
- **Same pattern works on Cloud Run, GCE, anywhere with WI.** Portable
  across compute platforms with one env-var change.
- **Worker's validation is ~30 LOC** (one middleware) and the api side
  is `idtoken.NewClient(ctx, audience)` — total ~10 LOC.
- **mTLS is the next-step prod upgrade**, via Linkerd — listed in
  [What's deferred](#whats-deferred-for-production). ID-token is the
  application-layer signal that survives a mesh outage.

---

## Architecture decisions

- **GKE Autopilot, not Standard.** Per-pod billing scales to ~$0 idle;
  Workload Identity, Shielded Nodes, NetworkPolicy enforcement, image
  streaming all on by default; no node-pool tuning to maintain. The
  trade-offs we accept: no DaemonSets (we don't ship any) and no
  per-pool spot pricing (we'd take spot via pod-spec when worth it).
  Cluster control-plane fee is ~$73/mo regardless of zonal vs regional
  (the "first zonal cluster free" tier ended in late 2023). For a
  one-team-one-product setup, Autopilot is still the lower-LOC answer
  vs Standard; on cost the two are now within margin of error.
- **Single zonal cluster.** `location: us-central1-a` (`var.zone`).
  Same ~$73/mo control-plane fee as regional but single-AZ blast
  radius — appropriate for dev. Multi-region / regional HA is "stamp
  the stack a second time pointed at a different region (and flip
  `location` to `var.region`)" — described in [Adding a second environment](#adding-a-production-environment-described-not-built).
- **Argo Rollouts for the canary.** The brief's "deploy a canary, run
  smoke tests, promote or roll back automatically" maps 1:1 to a
  Rollout/Canary with AnalysisTemplate gates. We get a 10% → 50% →
  100% step progression with `/readyz` Job probes between steps, not
  a rolling-update-with-rollback. Caveat with `replicas: 2` and no
  service mesh: ReplicaSet-based canary splits by **pod count**, so
  `setWeight: 10` actually scales the canary RS to 1 pod (~33–50% of
  traffic by kube-proxy RR) until the next step. To get true HTTP
  weighting, add NGINX Ingress / Linkerd / Istio as the
  `trafficRouting` provider — see [What's deferred](#whats-deferred-for-production).
  Controller cost: ~30m CPU / 100Mi RAM. The `Rollout` is identical
  to a `Deployment` minus the `strategy` block — no app code change.
- **Single-repo manifests, kubectl apply -k from CI** — not a separate
  manifest repo + Argo CD. GitOps with split repos earns its complexity
  at 2+ envs or 3+ teams; here it doubles the surface area without
  payoff. Convert to Argo CD when reconciliation drift across teams
  becomes a real cost. Note in [What's deferred](#whats-deferred-for-production).
- **GSM CSI driver, not External Secrets Operator.** Single secret
  (`db-app-password`) mounted directly from Secret Manager as a file
  via the GKE-managed Secrets Store CSI add-on
  (`secrets-store-gke.csi.k8s.io`); the api reads
  `$DB_PASSWORD_FILE = /var/run/secrets/gsm/db-password` at startup.
  No K8s Secret round-trip — Autopilot doesn't grant the managed
  driver KSA cluster-wide `secrets.list/watch`, so `secretObjects`
  sync doesn't work there anyway, and file-mount is the cleaner
  pattern (same shape as Cloud Run secret injection / Vault Agent).
  ESO pays for itself with N secrets × M namespaces; here it would be
  a controller in front of one binding.
- **Workload Identity, no JSON keys.** Both runtime KSAs (`ulys/api`,
  `ulys/worker`) are annotated with `iam.gke.io/gcp-service-account`,
  bound via `roles/iam.workloadIdentityUser` to the corresponding GSA.
  GitHub Actions assumes the deployer GSA via WIF with
  `attribute_condition` pinning trust to **one repository AND one
  GitHub Environment**.
- **Static external IP for the api LB.** Reserved by Terraform
  (`google_compute_address.api_lb`) and exported as
  `api_lb_static_ip`. The `Service/api-public` pins to it via
  `loadBalancerIP:` — gives a stable URL for the uptime check, the
  web bucket's `API_URL` substitution, and the submission table.
- **Cloud Monitoring uptime check + AlertPolicy** on
  `<api_lb_static_ip>/healthz` every 60s. Fires after 5 min of failure.
  Optional email channel via `ALERT_EMAIL` (unset disables only the
  email side; the alert still records to Cloud Logging).
- **Pod Security Standards `restricted`** at the namespace boundary.
  Combined with `runAsNonRoot: true`, `runAsUser: 65532`,
  `readOnlyRootFilesystem: true`, `capabilities: { drop: [ALL] }`.
- **Renovate** weekly grouped PRs for Go modules, GH Actions, Terraform
  providers; auto-merge on minor/patch when CI is green.

---

## Layout

```
apps/
  api/      cmd/api, internal/{db,server,telemetry}     Go: chi + pgx + redis
                                                         + idtoken.NewClient (worker auth)
  worker/   cmd/worker                                   Go: net/http + JWT-validate middleware
  web/      index.html                                   static, served from GCS
infra/                                                   Terraform (HCL)
  bootstrap/    one-shot: TF state bucket + WIF + deployer SA (local backend)
  envs/dev/     network + data + runtime + web + ops    (gcs backend)
manifests/                                               Kustomize
  base/         Rollout, Services, NetworkPolicy, SAs, SecretProviderClass,
                AnalysisTemplate
  overlays/dev/ image tags (CI-edited), ${VAR} values via envsubst
.github/workflows/
  ci-app.yml    test → manifests-lint → build matrix → kustomize apply →
                 kubectl argo rollouts status api → smoke → deploy-web
                 (on rollout Failed: Argo Rollouts auto-aborts;
                  CI also explicitly aborts + fails the job)
  ci-infra.yml  fmt + validate + plan-on-PR; apply on merge
justfile        just up / just down (terraform → cluster → helm → kubectl)
renovate.json   weekly grouped dep updates
```

---

## Estimated monthly cost (us-central1, idle, dev)

| | $/mo |
|---|---|
| GKE Autopilot zonal control plane | $0 (first zonal cluster per project is free) |
| Autopilot per-pod billing (4 small pods × ~24h) | ~$3-5 |
| Cloud SQL `db-f1-micro` Postgres + 10 GiB SSD | ~$9 |
| Memorystore Redis BASIC, 1 GiB | ~$35 |
| L4 LoadBalancer forwarding rule + egress | ~$5 |
| Cloud NAT + Logging + Monitoring | ~$3 |
| **Total dev idle** | **~$55-60/mo** |

The brief's $5–15 realistic-spend target only fits if you `terraform
destroy` between sessions — Memorystore alone is $35/mo whether or not
anything calls it. `just down` returns to $0 immediately (project
delete stops billing; 30-day undelete window).

A `$20` Cloud Billing budget with a 100% threshold alert is provisioned
in `infra/envs/dev/ops.tf` (the brief's required threshold), routed to
the `ALERT_EMAIL` channel when set.

---

## Adding a production environment (described, not built)

The repo deliberately ships only **one** stack to keep the codebase under
review. Adding `prod` is a **copy of `infra/envs/dev/`** with these diffs
— no new modules, no new patterns:

| Knob | dev (this repo) | prod (described) |
|---|---|---|
| GCP project | `ulys-dev-XXXXX` | separate `ulys-prod-XXXXX` |
| Bootstrap | `dev` (already supports any env suffix) | `just bootstrap ENV=prod` — same code, different `attribute_condition` |
| GKE control plane | zonal (~$73/mo, single AZ) | regional (~$73/mo, HA across all 3 zones — same fee, broader SLA) |
| Master authorized networks | `0.0.0.0/0` (dev convenience) | CI runner CIDR + bastion only |
| Cloud SQL | `db-f1-micro`, single AZ | `db-custom-2-7680`, `availability_type=REGIONAL`, `pitr=true`, CMEK |
| Memorystore | `BASIC` 1 GB, no AUTH | `STANDARD_HA` 5 GB, `auth_enabled=true`, `transit_encryption_mode=SERVER_AUTHENTICATION` |
| Image admission | none | BinAuthz + cosign-signed digests + KMS attestor |
| Secret rotation | none | rotation period set on `db-app-password` |
| Budget | $20, 100% threshold | $300, 50/90/100% thresholds |
| GH Environment | `dev` (auto-deploy) | `prod` with required reviewers |
| Promotion | every commit on main → canary on dev | `release-*` tag → digest-forward to prod (same digest that passed dev's canary) |

The Terraform modules accept the knobs above as variables —
`envs/prod/` would be ~150 lines of `module` blocks + `terraform.tfvars`.

---

## What's deferred for production

- **Linkerd service mesh.** Annotate the `ulys` namespace
  `linkerd.io/inject=enabled`. Get mTLS between api ↔ worker (the
  application-layer ID token check stays as belt-and-suspenders).
  Adds ~500 MiB. The Rollout's traffic split can move to
  SMI `TrafficSplit` for L7 weighting instead of ReplicaSet count
  + Service round-robin.
- **kube-prometheus-stack + Prometheus AnalysisTemplate.** Replace
  the curl-Job-based readyz probe with a Prometheus query against
  real canary traffic (`http_5xx_rate < 0.01`). Adds ~$30/mo.
- **Argo CD + split manifest repo.** Earns its complexity at 2+ envs
  or 3+ teams. Pattern: `ulys-manifests` repo with `apps/<env>/`
  Kustomize overlays, root Application + per-env ApplicationSet,
  Argo CD reconciles. CI's `bump-manifest` job replaces the current
  in-repo `kubectl apply -k` step.
- **Cloud Armor + global HTTPS LB + custom domain + managed cert.**
  Currently exposed via L4 LoadBalancer Service on a static external
  IP. Adds ~$18-25/mo.
- **BinAuthz + cosign-signed images.** CI cosign-signs every digest
  with the GH OIDC keyless flow; cluster's BinAuthz attestor verifies.
  ~5 lines of HCL once a release process exists to manage the KMS key.
  Skipped in dev because dev pushes hourly; prod's slower cadence makes
  the friction worth it.
- **Cloud SQL IAM auth via the Auth Proxy.** Currently the api uses
  plain DSN with the password from Secret Manager. Switching to IAM
  auth requires creating the postgres user with
  `--type=cloud_iam_service_account` in TF.
- **Atlas migrations** as a pre-deploy Job. Currently the api runs
  `CREATE TABLE IF NOT EXISTS hits` on boot.
- **OpenTelemetry collector + Cloud Trace.** App is wired with the
  OTel SDK (gated on `OTEL_ENABLE=true`); no collector deployed for
  the take-home — Cloud Logging picks up stdout natively.
- **Default-deny NetworkPolicy** with explicit DNS egress allow.
  Currently we ship the per-pod policy gating worker ingress; the
  default-deny baseline is a one-line addition once DNS egress is
  validated end-to-end.
- **SLOs.** Cloud Monitoring `Service` + SLO resource on
  `availability >= 99.5%` and `latency p95 < 500ms`, plus log-based
  metrics for HTTP 5xx ratio.

---

## References

- [Terraform google provider](https://registry.terraform.io/providers/hashicorp/google/latest/docs)
- [Argo Rollouts canary with AnalysisTemplate](https://argo-rollouts.readthedocs.io/en/stable/features/canary/)
- [Secrets Store CSI Driver — GCP provider](https://github.com/GoogleCloudPlatform/secrets-store-csi-driver-provider-gcp)
- [Workload Identity Federation for GitHub Actions](https://github.com/google-github-actions/auth)
- [GKE Autopilot overview](https://cloud.google.com/kubernetes-engine/docs/concepts/autopilot-overview)
