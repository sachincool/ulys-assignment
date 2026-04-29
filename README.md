# ulys (production rebuild)

A production-shaped rebuild of the [ulys-assignment](https://github.com/sachincool/ulys-assignment)
take-home. Same product surface (web → api → worker, with Postgres + Redis
behind it) — different operational shape: **GKE Standard, Pulumi (TypeScript),
GitOps with Argo CD + Flagger**, signed images, mesh-managed mTLS, structured
observability.

```
                  ┌───────────────────────┐
   client ───────▶│ External HTTPS LB     │
                  │ + Cloud Armor + IAP   │   (north-south)
                  └───────────────────────┘
                            │
                  ┌─────────▼──────────┐
                  │  GKE Standard      │
                  │  (zonal, private)  │
                  │                    │
                  │  ┌──────────────┐  │
                  │  │ api          │──┼───▶ worker (mTLS via Linkerd,
                  │  │ Deployment   │  │     ClusterIP, NetworkPolicy +
                  │  └──────┬───────┘  │     Linkerd AuthorizationPolicy)
                  │         │          │
                  │  Cloud SQL Auth Proxy (CSI volume)
                  │         │
                  └─────────┼──────────┘
                            │
                  ┌─────────▼──────────┐
                  │ Cloud SQL Postgres │ (private IP, IAM auth)
                  │ Memorystore Redis  │ (private IP, AUTH+TLS in stg/prod)
                  └────────────────────┘
```

## Why this is different from the take-home

| | take-home (Cloud Run) | this |
|---|---|---|
| IaC | Terraform HCL | **Pulumi TypeScript** |
| Compute | Cloud Run × 2 | **GKE Standard, zonal** |
| Service-to-service auth | per-call Google ID tokens | **Linkerd mTLS + AuthorizationPolicy** |
| Canary | gcloud `--tag=canary` + smoke curl | **Flagger** progressive delivery on Prometheus SLOs |
| Deploy mechanism | runner does `gcloud run deploy` | **GitOps**: runner bumps a manifest digest; Argo CD reconciles |
| DB password | Secret Manager mounted as env at TF time | **External Secrets Operator** + Cloud SQL IAM auth (no password on the wire) |
| Image trust | unsigned tags | **cosign** keyless signing, **SBOM + Trivy** as cosign attestations |
| Multi-env | one project | **3 GCP projects** with image-digest promotion |

## Why GKE Standard (not Autopilot)

Autopilot is correct for a multi-team platform; for a single-product team
the constraints (no privileged DaemonSets in `kube-system`, ~30% pod-hour
overhead, regional control plane only) cost more than they save. **Standard
zonal** has a free control plane (one cluster per project) and the same
best-practice features can be applied explicitly:

- private cluster, private endpoint
- Workload Identity (the only auth path for pods to GCP APIs)
- NetworkPolicy enforcement (Calico)
- Shielded nodes (secure boot + integrity monitoring)
- Release channel: `REGULAR` (Google rolls minor upgrades)
- Auto-repair + auto-upgrade on the node pool
- Managed Prometheus on the cluster

Defaults in `infra/components/gke.ts` give "minimum prod" — single zone,
one e2-standard-2 node pool, autoscale 1..3. Multi-zone or multi-region
upgrades are documented one-line changes (see "Scaling further" below);
day-one is intentionally single-region single-zone.

## Why Linkerd (not Istio)

For one product team, Linkerd ships mTLS, retries, and traffic-splitting
in a Rust micro-proxy (~20 MB pod overhead) with on-by-default policy.
Istio's Envoy sidecar is ~150 MB and the YAML surface is a separate skill.
The day Istio earns its keep is the day you have a real reason to care about
JWT validation at the mesh, advanced AuthorizationPolicy, or VirtualService
fan-out — none of that on day one.

## Repo layout

```
ulys-prod/                          # this repo (source + infra)
├── apps/
│   ├── api/        cmd/api, internal/{db,redis,server,telemetry}
│   └── worker/     cmd/worker, internal/server
├── infra/          Pulumi TypeScript
│   ├── bootstrap/  one-shot per env: state bucket, WIF, deployer SA
│   ├── components/ gke / postgres / memorystore / secrets / wi / binauthz
│   └── stacks/     dev / staging / prod
└── .github/workflows/
    ├── ci-app.yml      build + scan + sign + manifest-bump PR
    ├── ci-infra.yml    pulumi preview on PR; pulumi up on merge per env
    └── promote.yml     manual: copy a signed digest from one env to the next

ulys-manifests/                     # GitOps repo, separate
├── argocd-applications/            # App-of-Apps root + per-env children
├── platform/{base,dev,staging,prod}  # Linkerd, Flagger, ESO, OTel collector,
│                                     # default-deny NetworkPolicy
└── apps/{base,dev,staging,prod}      # api/worker Deployment + Service +
                                       # Canary CR + ExternalSecret + NetworkPolicy
```

## Setup (fresh GCP projects)

You need three GCP projects (`ulys-dev-…`, `ulys-staging-…`, `ulys-prod-…`),
each linked to the same billing account, plus this repo + an empty
`ulys-manifests` repo for GitOps.

### One-shot per env

```bash
cd infra/bootstrap
pnpm install
pulumi stack init dev-bootstrap
pulumi config set gcp:project   ulys-dev-XXXXXX
pulumi config set ulys-bootstrap:githubRepo sachincool/ulys
pulumi up

# Outputs go into the env stack's Pulumi.<env>.yaml backend config.
pulumi stack output stateBucketName
pulumi stack output wifProviderResource
pulumi stack output deployerSaEmail
```

Repeat for staging-bootstrap and prod-bootstrap.

### Per-env stack

```bash
cd infra/stacks/dev
pulumi stack init dev
pulumi config set gcp:project   ulys-dev-XXXXXX
pulumi up                       # creates VPC, GKE, Cloud SQL, Memorystore,
                                # Artifact Registry, IAM, secrets
```

Once `pulumi up` returns:

```bash
gcloud container clusters get-credentials ulys-gke \
  --location=us-central1-a --project=ulys-dev-XXXXXX

# Install Argo CD once per cluster:
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Point Argo CD at the manifests repo:
kubectl apply -n argocd -f https://github.com/sachincool/ulys-manifests/raw/main/argocd-applications/root.yaml
```

That's the last imperative step. From then on, every change goes through a
PR: app changes hit `ci-app.yml` → CI signs an image and opens a manifest
PR → Argo CD reconciles after merge → Flagger does the canary.

## Forcing function (canary rollback) — same demo, different mechanism

Identical to the take-home in spirit: push a commit that intentionally
breaks `/readyz`, observe the rollout abort. Mechanically very different:

1. Push a commit to `apps/api/internal/server/handlers.go` that returns
   503 unconditionally from `Readyz`.
2. CI builds + signs the image, opens a manifest-bump PR for dev.
3. Merge that PR. Argo CD reconciles the Deployment.
4. Flagger detects the new `targetRef`, spins up the canary ReplicaSet,
   shifts 10% traffic.
5. Flagger queries Prometheus for the canary's `request-success-rate`
   and `request-duration` over the last minute. Both come from the
   Linkerd proxy metrics (the success rate immediately tanks).
6. Threshold breach → Flagger aborts the rollout, scales down the canary
   ReplicaSet, restores 100% to the stable. **Public traffic exposure to
   the bad revision: ≤10%, ≤1 minute.**
7. Push the revert commit. Same flow, smoke passes, Flagger promotes.

The win over the take-home: no per-step shell, no smoke curls, no manual
rollback step in the workflow. Real metrics-driven progressive delivery.

## Scaling further (one-line upgrades)

| upgrade | change |
|---|---|
| Regional control plane (HA) | `location: zone` → `location: region` in `infra/stacks/<env>/index.ts`. ~$73/mo. |
| Multi-zone nodes (zonal HA) | `nodeLocations: [a]` → `[a, b, c]`. Adds zonal redundancy; cost roughly 3× node count. |
| Multi-region (active-active) | Stamp the stack a second time pointed at a different region. Add a multi-region NEG to the LB. Don't try to make one cluster span regions. |
| Read replicas | Already in `infra/stacks/prod/index.ts`. dev/staging skip. |
| Cloud Armor + IAP | Set on the BackendConfig in `apps/base/api/service.yaml`; needs an OAuth client ID per env. |

## Cost (idle, USD)

| env | rough monthly | what dominates |
|---|---|---|
| dev | $70-90 | Memorystore (~$35) + Cloud SQL f1-micro (~$15) + node (~$30 spot). Cluster control plane $0 (zonal). |
| staging | $120-150 | + Cloud SQL HA tier (~$35), AUTH+TLS Memorystore (~$5 extra). |
| prod | $250-300 | + regional control plane ($73), HA db-custom-2-7680 (~$90), STANDARD_HA Memorystore 5GB (~$70). |

`pulumi destroy` returns each env to $0. There's no "delete the project"
plan B because each env's project is exactly its own scope — destroying
the stack is sufficient.

## What's still skipped (and why)

- **Multi-region.** Single region until SLO budget says otherwise.
- **Service mesh ambient mode.** Sidecar Linkerd is mature; ambient is
  fine but not yet the default.
- **Custom auth (Dex / Keycloak).** Use Google IAP at the LB until there's
  a multi-IdP requirement.
- **Self-hosted Prometheus / Loki / Tempo.** Cloud Monitoring/Logging/Trace
  is cheaper and lower-ops at our scale.
- **Per-PR ephemeral environments.** vcluster makes this easy later; not
  day-one.
- **Crossplane.** Pulumi covers everything; Crossplane is for ≥3-team
  self-service, which we don't have.

These all live as ADRs under `docs/adr/` so the choice is reviewable.

## ADRs

- [`docs/adr/0001-why-we-left-cloud-run.md`](docs/adr/0001-why-we-left-cloud-run.md) —
  what nine bug-iterations on the take-home taught us about Cloud Run's
  fit for this product.
