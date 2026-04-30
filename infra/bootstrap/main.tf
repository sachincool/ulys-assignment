resource "google_storage_bucket" "tf_state" {
  name                        = "${var.project}-tf-state"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = false

  versioning { enabled = true }

  lifecycle_rule {
    condition { num_newer_versions = 10 }
    action { type = "Delete" }
  }
}

resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github-${var.env}"
  display_name              = "GitHub Actions (${var.env})"
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-provider"

  attribute_mapping = {
    "google.subject"        = "assertion.sub"
    "attribute.repository"  = "assertion.repository"
    "attribute.ref"         = "assertion.ref"
    "attribute.environment" = "assertion.environment"
  }

  # Pin trust to one repo AND one GitHub Environment matching this stack.
  attribute_condition = "assertion.repository == \"${var.github_repo}\" && assertion.environment == \"${var.env}\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account" "deployer" {
  account_id   = "gh-deployer-${var.env}"
  display_name = "GitHub Actions deployer (${var.env})"
}

resource "google_service_account_iam_member" "deployer_wif" {
  service_account_id = google_service_account.deployer.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repo}"
}

# Curated role set — no Owner. roles/billing.user is granted out-of-band by
# the justfile against the billing account (it isn't a project-level role).
# Each role here corresponds to a resource type this stack actually creates.
# run.admin (Cloud Run) and vpcaccess.admin (serverless VPC connector) were
# trimmed — neither resource family is provisioned by this stack. Re-add
# them only when those resources are reintroduced.
locals {
  deployer_roles = [
    "roles/artifactregistry.admin",
    "roles/cloudsql.admin",
    "roles/compute.networkAdmin",
    "roles/compute.securityAdmin",
    "roles/iam.serviceAccountAdmin",
    "roles/iam.serviceAccountUser",
    "roles/redis.admin",
    "roles/secretmanager.admin",
    "roles/servicenetworking.networksAdmin",
    "roles/serviceusage.serviceUsageAdmin",
    "roles/storage.admin",
    "roles/monitoring.editor",
  ]
}

resource "google_project_iam_member" "deployer" {
  for_each = toset(local.deployer_roles)
  project  = var.project
  role     = each.value
  member   = "serviceAccount:${google_service_account.deployer.email}"
}
