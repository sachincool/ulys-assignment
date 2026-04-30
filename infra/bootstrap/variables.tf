variable "project" {
  description = "GCP project ID this bootstrap is being applied to."
  type        = string
}

variable "region" {
  description = "Default region for regional resources."
  type        = string
  default     = "us-central1"
}

variable "env" {
  description = "Environment name (dev / staging / prod). Pinned into the WIF attribute_condition."
  type        = string
  default     = "dev"
}

variable "github_repo" {
  description = "GitHub repo in 'owner/name' form. Pinned into the WIF attribute_condition."
  type        = string
}
