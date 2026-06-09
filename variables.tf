variable "hetzner_token" {
  description = "Hetzner Cloud API token"
  type        = string
  sensitive   = true
}

variable "server_name" {
  description = "Name prefix for all Hetzner resources"
  type        = string
  default     = "fleet-mdm"
}

variable "domain" {
  description = "Fleet MDM public domain — Caddy requests a TLS cert for this hostname"
  type        = string
  default     = "fleet.example.com"
}

variable "admin_email" {
  description = "Email address for Let's Encrypt cert expiry notifications"
  type        = string
  default     = "admin@example.com"
}

# ── Server ────────────────────────────────────────────────────────────────────

variable "server_type" {
  description = <<-EOT
    Hetzner server type. cpx22 (2 vCPU, 4 GB Intel) is the primary choice.
    If the plan fails with a resource_unavailable error, change to the next
    available type for the target location:
      nbg1: cpx22 → cx23
      fsn1: cpx22 → cx23
  EOT
  type    = string
  default = "cpx22"
}

variable "location" {
  description = "Hetzner datacenter location"
  type        = string
  default     = "nbg1" # Nuremberg — cx23 available here per user observation

  validation {
    condition     = contains(["fsn1", "nbg1", "hel1", "ash", "hil", "sin"], var.location)
    error_message = "location must be one of: fsn1, nbg1, hel1, ash, hil, sin"
  }
}

variable "image_name" {
  description = "Hetzner system image name (openSUSE Leap)"
  type        = string
  default     = "opensuse-16"
}

variable "fleet_version" {
  description = "Fleet Docker image tag. Pin to a specific release — 'latest' tracks development builds."
  type        = string
  default     = "v4.86.0"
}

variable "fleet_license_key" {
  description = <<-EOT
    Fleet Premium license key. Leave empty for Community Edition.
    Obtain from: https://fleetdm.com/customers
  EOT
  type      = string
  default   = ""
  sensitive = true
}

# ── S3 Object Storage ─────────────────────────────────────────────────────────

variable "s3_access_key" {
  description = <<-EOT
    Hetzner Object Storage access key for Fleet software package distribution.
    Leave empty to skip S3 setup (Fleet will still work; software packages won't).
    Create credentials: https://console.hetzner.com → Object Storage → Access Keys
  EOT
  type      = string
  default   = ""
  sensitive = true
}

variable "s3_secret_key" {
  description = "Hetzner Object Storage secret key"
  type        = string
  default     = ""
  sensitive   = true
}

