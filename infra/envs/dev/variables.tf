variable "project" {
  description = "GCP project ID."
  type        = string
}

variable "region" {
  description = "Default region."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "Default zone inside var.region. Not used by the GKE cluster (Autopilot is regional only); retained for future zonal resources (single-zone Memorystore replicas, CloudSQL HA peer, etc.)."
  type        = string
  default     = "us-central1-a"
}

variable "billing_account" {
  description = "Billing account ID — required by the budget resource."
  type        = string
}

variable "alert_email" {
  description = "Email that receives uptime + budget alerts. Empty disables the email channel."
  type        = string
  default     = ""
}

variable "budget_amount" {
  description = "Monthly budget amount, denominated in the billing account's native currency (USD for US accounts, INR for IN accounts, etc.). 2000 ≈ ₹2000 ≈ $24, both reasonable for a dev sandbox."
  type        = number
  default     = 2000
}
