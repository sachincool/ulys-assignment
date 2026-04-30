# ulys — plug-and-play spin up / spin down via just (https://just.systems)
#
# Pre-reqs (one-time on the operator's laptop):
#   brew install just pulumi pnpm gcloud kubectl helm gh
#   gcloud auth login
#   gcloud auth application-default login
#
# Usage:
#   just up   PROJECT_ID=ulys-dev-XXXXX BILLING_ACCOUNT=01XXXX-XXXXXX-XXXXXX
#   just down PROJECT_ID=ulys-dev-XXXXX
#
# `up` orchestrates: GCP project create + billing → enable APIs → bootstrap
# stack → env stack → install Argo CD root Application → wait for Healthy.
# `down` runs `pulumi destroy` on the env stack and the bootstrap stack,
# then `gcloud projects delete`.
#
# Everything else flows through GitOps: image bumps go via `ci-app.yml`,
# manifest commits go via the manifest-bump PR, Argo CD reconciles.

set shell := ["bash", "-eu", "-o", "pipefail", "-c"]
set positional-arguments

env             := env_var_or_default("ENV", "dev")
project_id      := env_var_or_default("PROJECT_ID", "")
billing_account := env_var_or_default("BILLING_ACCOUNT", "")
github_repo     := env_var_or_default("GITHUB_REPO", "sachincool/ulys-assignment")
manifest_repo   := env_var_or_default("MANIFEST_REPO", "sachincool/ulys-manifests")
region          := env_var_or_default("REGION", "us-central1")

# Per-env stable passphrase. In CI, pull from Pulumi config env or a secret.
export PULUMI_CONFIG_PASSPHRASE := "ulys-" + env + "-passphrase"

# Default action: list available recipes
default:
    @just --list --unsorted

# Spin up a fresh env from scratch (project create → cluster ready → apps Healthy)
up: bootstrap stack argocd verify
    @echo
    @echo "✅ ulys-{{env}} is up. Argo CD is reconciling from {{manifest_repo}}."
    @echo "   - Cluster:  $(cd infra/stacks/{{env}} && pulumi stack output clusterName)"
    @echo "   - api LB:   http://$(kubectl -n ulys get svc api-public -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
    @echo "   - argocd:   kubectl -n argocd port-forward svc/argo-cd-argocd-server 8080:80"

# Step 1: GCP project + billing + APIs + Pulumi bootstrap stack + GH vars
bootstrap:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${PROJECT_ID:={{project_id}}}"
    [[ -n "${PROJECT_ID}" ]] || { echo "PROJECT_ID required (e.g., just bootstrap PROJECT_ID=ulys-dev-1)"; exit 1; }
    : "${BILLING_ACCOUNT:={{billing_account}}}"
    [[ -n "${BILLING_ACCOUNT}" ]] || { echo "BILLING_ACCOUNT required"; exit 1; }

    echo "==> create project $PROJECT_ID (idempotent)"
    gcloud projects describe "$PROJECT_ID" >/dev/null 2>&1 || \
      gcloud projects create "$PROJECT_ID" --name=ulys-{{env}}
    gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT" >/dev/null
    gcloud config set project "$PROJECT_ID" >/dev/null
    gcloud auth application-default set-quota-project "$PROJECT_ID" 2>/dev/null || true

    echo "==> enable APIs (one batch)"
    gcloud services enable \
      iam.googleapis.com iamcredentials.googleapis.com \
      cloudresourcemanager.googleapis.com serviceusage.googleapis.com \
      compute.googleapis.com container.googleapis.com \
      sqladmin.googleapis.com redis.googleapis.com \
      servicenetworking.googleapis.com artifactregistry.googleapis.com \
      secretmanager.googleapis.com cloudkms.googleapis.com cloudbilling.googleapis.com \
      storage.googleapis.com monitoring.googleapis.com logging.googleapis.com \
      cloudtrace.googleapis.com binaryauthorization.googleapis.com containeranalysis.googleapis.com \
      --project="$PROJECT_ID" >/dev/null

    echo "==> infra/bootstrap (state bucket + WIF + curated deployer SA)"
    (cd infra && pnpm install --silent)
    (cd infra/bootstrap && \
       (pulumi login file://./pulumi-state >/dev/null 2>&1 || true) && \
       (pulumi stack select {{env}}-bootstrap >/dev/null 2>&1 || pulumi stack init {{env}}-bootstrap >/dev/null) && \
       pulumi config set gcp:project "$PROJECT_ID" && \
       pulumi config set gcp:region {{region}} && \
       pulumi config set ulys-bootstrap:githubRepo {{github_repo}} && \
       pulumi up --yes --skip-preview)

    echo "==> wire GitHub Actions vars on {{github_repo}}"
    WIF=$(cd infra/bootstrap && pulumi stack output wifProviderResource)
    DEPLOYER=$(cd infra/bootstrap && pulumi stack output deployerSaEmail)
    UPPER=$(echo "{{env}}" | tr '[:lower:]' '[:upper:]')
    gh variable set "GCP_PROJECT_ID_${UPPER}" -b "$PROJECT_ID" -R {{github_repo}}
    gh variable set "WIF_PROVIDER_${UPPER}"   -b "$WIF"        -R {{github_repo}}
    gh variable set "DEPLOYER_SA_${UPPER}"    -b "$DEPLOYER"   -R {{github_repo}}
    gh variable set GCP_REGION                 -b "{{region}}"  -R {{github_repo}} || true

# Step 2: VPC + GKE + Cloud SQL + Memorystore + IAM (the env-specific stack)
stack:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${PROJECT_ID:={{project_id}}}"
    [[ -n "${PROJECT_ID}" ]] || { echo "PROJECT_ID required"; exit 1; }

    echo "==> infra/stacks/{{env}} (cluster + DB + cache + IAM)"
    cd infra/stacks/{{env}}
    pulumi login "gs://${PROJECT_ID}-pulumi-state" >/dev/null
    pulumi stack select {{env}} >/dev/null 2>&1 || pulumi stack init {{env}} >/dev/null
    pulumi config set gcp:project "$PROJECT_ID"
    pulumi config set gcp:region {{region}}
    pulumi up --yes --skip-preview

# Step 3: get cluster credentials, apply Argo CD root Application
argocd:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${PROJECT_ID:={{project_id}}}"
    [[ -n "${PROJECT_ID}" ]] || { echo "PROJECT_ID required"; exit 1; }

    echo "==> kube credentials + Argo CD bootstrap"
    CLUSTER_NAME=$(cd infra/stacks/{{env}} && pulumi stack output clusterName)
    CLUSTER_LOC=$(cd infra/stacks/{{env}} && pulumi stack output clusterLocation)
    gcloud container clusters get-credentials "$CLUSTER_NAME" \
      --location="$CLUSTER_LOC" --project="$PROJECT_ID" >/dev/null
    kubectl apply -f https://raw.githubusercontent.com/{{manifest_repo}}/main/argocd-applications/root.yaml
    kubectl apply -f https://raw.githubusercontent.com/{{manifest_repo}}/main/argocd-applications/platform-{{env}}.yaml
    echo "Argo CD is reconciling. Run 'just verify' to wait until apps are Healthy."

# Step 4: wait for the per-env Application to reach Healthy (timeout 8m)
verify:
    @echo "==> waiting for apps-{{env}} Healthy (timeout 8m)"
    kubectl -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy application/apps-{{env}} --timeout=8m

# Tear it all back down: env stack → bootstrap → project delete
down:
    #!/usr/bin/env bash
    set -uo pipefail   # keep going on individual destroy errors
    : "${PROJECT_ID:={{project_id}}}"
    [[ -n "${PROJECT_ID}" ]] || { echo "PROJECT_ID required"; exit 1; }

    echo "==> tear down env stack ({{env}})"
    (cd infra/stacks/{{env}} && pulumi destroy --yes --skip-preview) || true

    echo "==> tear down bootstrap"
    (cd infra/bootstrap && pulumi stack select {{env}}-bootstrap >/dev/null 2>&1 && \
       pulumi destroy --yes --skip-preview) || true

    echo "==> delete project (immediate billing stop, 30d undelete window)"
    gcloud projects delete "$PROJECT_ID" --quiet || true

# Quick checks against the live cluster (use after `just up`)
status:
    @echo "=== applications ==="
    @kubectl -n argocd get applications 2>/dev/null || echo "(no cluster context)"
    @echo
    @echo "=== ulys workloads ==="
    @kubectl -n ulys get rollout,svc,pods 2>/dev/null || true
    @echo
    @echo "=== api LB IP ==="
    @kubectl -n ulys get svc api-public -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null && echo "" || echo "n/a"

# Smoke against the live LB
smoke:
    #!/usr/bin/env bash
    set -euo pipefail
    LB=$(kubectl -n ulys get svc api-public -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    [[ -n "$LB" ]] || { echo "no LB IP yet"; exit 1; }
    echo "LB: http://$LB"
    for p in /livez /healthz /readyz /version /work; do
      code=$(curl -sk -o /dev/null -m 8 -w '%{http_code}' "http://$LB$p" || echo 0)
      echo "  $p -> $code"
    done

# Local cleanup (drop pnpm + Pulumi state caches)
clean:
    rm -rf infra/node_modules
    rm -rf infra/bootstrap/pulumi-state
    rm -rf infra/bootstrap/.pulumi infra/stacks/*/.pulumi
