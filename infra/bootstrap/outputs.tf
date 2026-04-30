output "state_bucket_name" {
  description = "GCS bucket holding remote Terraform state for the env stack."
  value       = google_storage_bucket.tf_state.name
}

output "wif_provider_resource" {
  description = "Full resource path of the WIF provider (used by google-github-actions/auth)."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "deployer_sa_email" {
  description = "Email of the GitHub Actions deployer service account."
  value       = google_service_account.deployer.email
}
