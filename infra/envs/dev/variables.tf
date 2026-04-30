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
  description = "Zone for the GKE Autopilot control plane. Setting this picks a zonal cluster (lower fee than regional, single-AZ blast radius — fine for dev). Must be inside var.region."
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
