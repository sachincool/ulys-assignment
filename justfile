# ulys — plug-and-play spin up / spin down via just (https://just.systems)
#
# Pre-reqs (one-time on the operator's laptop):
#   brew install just terraform pnpm gcloud kubectl helm gh kustomize
#   gcloud auth login
#   gcloud auth application-default login
#
# Usage:
#   just up   PROJECT_ID=ulys-dev-XXXXX BILLING_ACCOUNT=01XXXX-XXXXXX-XXXXXX
#   just down PROJECT_ID=ulys-dev-XXXXX
#
# `up` orchestrates: GCP project create + billing → enable APIs → bootstrap
# stack → env stack → cluster credentials → install argo-rollouts + GSM CSI
# → render + apply manifests → wait until Rollout is Healthy.

set shell := ["bash", "-eu", "-o", "pipefail", "-c"]
set positional-arguments

env             := env_var_or_default("ENV", "dev")
project_id      := env_var_or_default("PROJECT_ID", "")
billing_account := env_var_or_default("BILLING_ACCOUNT", "")
github_repo     := env_var_or_default("GITHUB_REPO", "sachincool/ulys-assignment")
region          := env_var_or_default("REGION", "us-central1")
alert_email     := env_var_or_default("ALERT_EMAIL", "")

default:
    @just --list --unsorted

# Spin up a fresh env from scratch
up: bootstrap stack platform deploy verify
    @echo
    @echo "ulys-{{env}} is up."
    @echo "  api:  http://$(cd infra/envs/{{env}} && terraform output -raw api_lb_static_ip)"
    @echo "  web:  $(cd infra/envs/{{env}} && terraform output -raw web_url)"

# Step 1: GCP project + billing + APIs + Terraform bootstrap + GH vars
bootstrap:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${PROJECT_ID:={{project_id}}}"
    [[ -n "${PROJECT_ID}" ]] || { echo "PROJECT_ID required"; exit 1; }
    : "${BILLING_ACCOUNT:={{billing_account}}}"
    [[ -n "${BILLING_ACCOUNT}" ]] || { echo "BILLING_ACCOUNT required"; exit 1; }

    echo "==> create project $PROJECT_ID (idempotent)"
    gcloud projects describe "$PROJECT_ID" >/dev/null 2>&1 || \
      gcloud projects create "$PROJECT_ID" --name=ulys-{{env}}
    gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT" >/dev/null
    gcloud config set project "$PROJECT_ID" >/dev/null

    echo "==> enable bootstrap-required APIs"
    gcloud services enable \
      iam.googleapis.com iamcredentials.googleapis.com \
      cloudresourcemanager.googleapis.com serviceusage.googleapis.com \
      cloudbilling.googleapis.com billingbudgets.googleapis.com \
      storage.googleapis.com \
      --project="$PROJECT_ID" >/dev/null

    echo "==> point Application Default Credentials at $PROJECT_ID"
    # Required: Terraform's google provider routes API calls through
    # ADC's quota project. If ADC still points at a deleted project,
    # downstream calls 403 even though the new project's IAM is fine.
    gcloud auth application-default set-quota-project "$PROJECT_ID"

    echo "==> wait 10s for project IAM propagation"
    sleep 10

    echo "==> infra/bootstrap (state bucket + WIF + deployer SA)"
    cd infra/bootstrap
    terraform init -upgrade
    terraform apply -auto-approve \
      -var "project=$PROJECT_ID" \
      -var "region={{region}}" \
      -var "env={{env}}" \
      -var "github_repo={{github_repo}}"

    echo "==> grant deployer SA roles/billing.user on the billing account"
    DEPLOYER=$(terraform output -raw deployer_sa_email)
    gcloud billing accounts add-iam-policy-binding "$BILLING_ACCOUNT" \
      --member="serviceAccount:$DEPLOYER" \
      --role="roles/billing.user" >/dev/null

    echo "==> wire GitHub Actions vars on {{github_repo}}"
    WIF=$(terraform output -raw wif_provider_resource)
    UPPER=$(echo "{{env}}" | tr '[:lower:]' '[:upper:]')
    gh variable set "GCP_PROJECT_ID_${UPPER}" -b "$PROJECT_ID" -R {{github_repo}}
    gh variable set "WIF_PROVIDER_${UPPER}"   -b "$WIF"        -R {{github_repo}}
    gh variable set "DEPLOYER_SA_${UPPER}"    -b "$DEPLOYER"   -R {{github_repo}}
    gh variable set GCP_REGION                 -b "{{region}}"  -R {{github_repo}} || true
    if [[ -n "{{alert_email}}" ]]; then
      gh variable set ALERT_EMAIL              -b "{{alert_email}}" -R {{github_repo}} || true
    fi
    gh secret set BILLING_ACCOUNT              -b "$BILLING_ACCOUNT" -R {{github_repo}} || true

# Step 2: VPC + GKE Autopilot + Cloud SQL + Memorystore + AR + IAM + budget
stack:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${PROJECT_ID:={{project_id}}}"
    [[ -n "${PROJECT_ID}" ]] || { echo "PROJECT_ID required"; exit 1; }
    : "${BILLING_ACCOUNT:={{billing_account}}}"
    [[ -n "${BILLING_ACCOUNT}" ]] || { echo "BILLING_ACCOUNT required"; exit 1; }

    cd infra/envs/{{env}}
    terraform init \
      -backend-config="bucket=${PROJECT_ID}-tf-state" \
      -backend-config="prefix=envs/{{env}}" \
      -upgrade
    terraform apply -auto-approve \
      -var "project=$PROJECT_ID" \
      -var "region={{region}}" \
      -var "billing_account=$BILLING_ACCOUNT" \
      -var "alert_email={{alert_email}}"

# Step 3: cluster creds + install argo-rollouts + Secrets Store CSI + GCP provider
platform:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${PROJECT_ID:={{project_id}}}"

    echo "==> kube credentials"
    CLUSTER_NAME=$(cd infra/envs/{{env}} && terraform output -raw cluster_name)
    CLUSTER_LOC=$(cd infra/envs/{{env}} && terraform output -raw cluster_location)
    gcloud container clusters get-credentials "$CLUSTER_NAME" \
      --location="$CLUSTER_LOC" --project="$PROJECT_ID"

    echo "==> Argo Rollouts (canary controller)"
    helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
    helm repo update >/dev/null
    helm upgrade --install argo-rollouts argo/argo-rollouts \
      --namespace argo-rollouts --create-namespace \
      --set installCRDs=true \
      --wait --timeout 5m

    echo "==> enable GKE-managed Secret Manager add-on (replaces helm install)"
    # Autopilot forbids helm installs into kube-system, so we use the managed
    # add-on. The flag is idempotent. Once GA in google provider v6, this
    # should move into the cluster resource.
    gcloud container clusters update "$CLUSTER_NAME" \
      --location="$CLUSTER_LOC" --project="$PROJECT_ID" \
      --enable-secret-manager
    kubectl get crd secretproviderclasses.secrets-store.csi.x-k8s.io -o name

# Step 4: render + apply manifests (kustomize + envsubst), trigger initial rollout
deploy:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${PROJECT_ID:={{project_id}}}"

    cd infra/envs/{{env}}
    export PROJECT_ID
    export API_LB_STATIC_IP=$(terraform output -raw api_lb_static_ip)
    export API_GSA_EMAIL=$(terraform output -raw api_sa_email)
    export WORKER_GSA_EMAIL=$(terraform output -raw worker_sa_email)
    export DB_HOST=$(terraform output -raw db_private_ip)
    export REDIS_ADDR="$(terraform output -raw redis_host):$(terraform output -raw redis_port)"
    cd ../../..

    # First-time deploy uses placeholder image refs (TF doesn't push images).
    # CI does the real digest bumps; for local `just up` the placeholders
    # are deliberately invalid so the Rollout sits in `Progressing` until
    # `ci-app.yml` runs against this cluster.
    kustomize build manifests/overlays/{{env}} | envsubst | kubectl apply -f -

# Step 5: wait for Rollout to reach Healthy (timeout 10m)
verify:
    @echo "==> waiting for Rollout/api to be Healthy (timeout 10m)"
    kubectl argo rollouts status api -n ulys --timeout 10m

# Smoke against the live LB
smoke:
    #!/usr/bin/env bash
    set -euo pipefail
    LB=$(cd infra/envs/{{env}} && terraform output -raw api_lb_static_ip)
    [[ -n "$LB" ]] || { echo "no LB IP"; exit 1; }
    echo "LB: http://$LB"
    for p in /livez /healthz /readyz /version /work; do
      code=$(curl -sk -o /dev/null -m 8 -w '%{http_code}' "http://$LB$p" || echo 0)
      echo "  $p -> $code"
    done

# Tear it all back down: env → bootstrap → project delete
down:
    #!/usr/bin/env bash
    set -uo pipefail
    : "${PROJECT_ID:={{project_id}}}"
    [[ -n "${PROJECT_ID}" ]] || { echo "PROJECT_ID required"; exit 1; }

    echo "==> tear down env stack ({{env}})"
    (cd infra/envs/{{env}} && terraform destroy -auto-approve \
      -var "project=$PROJECT_ID" \
      -var "region={{region}}" \
      -var "billing_account=${BILLING_ACCOUNT:-unused-on-destroy}" \
      -var "alert_email={{alert_email}}") || true

    echo "==> tear down bootstrap"
    (cd infra/bootstrap && terraform destroy -auto-approve \
      -var "project=$PROJECT_ID" \
      -var "region={{region}}" \
      -var "env={{env}}" \
      -var "github_repo={{github_repo}}") || true

    echo "==> delete project (immediate billing stop, 30d undelete window)"
    gcloud projects delete "$PROJECT_ID" --quiet || true

# Quick cluster snapshot
status:
    @echo "=== rollout ==="
    @kubectl argo rollouts get rollout api -n ulys 2>/dev/null || echo "(no cluster)"
    @echo
    @echo "=== ulys workloads ==="
    @kubectl -n ulys get rollout,deploy,svc,pods 2>/dev/null || true

# Local cleanup
clean:
    rm -rf infra/bootstrap/.terraform infra/bootstrap/terraform.tfstate*
    rm -rf infra/envs/{{env}}/.terraform infra/envs/{{env}}/.terraform.lock.hcl
