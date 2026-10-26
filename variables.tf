variable "hetzner_token" {
  description = "Hetzner Cloud API token"
  type        = string
  sensitive   = true
}

variable "state_passphrase" {
  description = <<-EOT
    Passphrase that encrypts the OpenTofu state and plan files (min 16 chars).
    Keep it in a password manager and pass it as TF_VAR_state_passphrase rather
    than in terraform.tfvars. Losing it makes the state unreadable.
  EOT
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.state_passphrase) >= 16
    error_message = "state_passphrase must be at least 16 characters."
  }
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

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$", var.domain))
    error_message = "domain must be a valid fully-qualified domain name (e.g. fleet.example.com)"
  }
}

variable "admin_email" {
  description = "Email address for Let's Encrypt cert expiry notifications"
  type        = string
  default     = "admin@example.com"

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.admin_email))
    error_message = "admin_email must be a valid email address"
  }
}

variable "admin_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach port 22 (SSH). Set to your own IP(s) to restrict
    access. Accepts IPv4 and IPv6 ranges. Example: ["203.0.113.5/32", "2001:db8::/32"]
    Setting this to ["0.0.0.0/0", "::/0"] leaves SSH open to the world — use
    only for initial setup or when your IP is dynamic.
  EOT
  type        = list(string)
  default     = null

  validation {
    condition     = var.admin_cidrs != null
    error_message = "admin_cidrs must be set explicitly. Use [\"0.0.0.0/0\", \"::/0\"] to allow all IPs (not recommended for production)."
  }
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
  type        = string
  default     = "cpx22"

  validation {
    condition     = contains(["cx22", "cx32", "cx42", "cx52", "cpx11", "cpx21", "cpx22", "cpx31", "cpx41", "cpx51", "cax11", "cax21", "cax31", "cax41", "cx23", "cx33", "cx43", "cx53"], var.server_type)
    error_message = "server_type must be a valid Hetzner server type (e.g. cpx22, cx23, cax21)"
  }
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
  default     = "v4.92.3"

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+$", var.fleet_version))
    error_message = "fleet_version must match vX.Y.Z (e.g. v4.92.3)"
  }
}

variable "mysql_version" {
  description = "MySQL Docker image tag. Pin to an exact patch version."
  type        = string
  default     = "8.0.42"
}

variable "redis_version" {
  description = "Redis Docker image tag. Pin to an exact patch version."
  type        = string
  default     = "7.2.6-alpine"
}

variable "fleet_license_key" {
  description = <<-EOT
    Fleet Premium license key. Leave empty for Community Edition.
    Obtain from: https://fleetdm.com/customers
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

# ── S3 Object Storage ─────────────────────────────────────────────────────────

variable "s3_access_key" {
  description = <<-EOT
    Hetzner Object Storage access key for Fleet software package distribution.
    Leave empty to skip S3 setup (Fleet will still work; software packages won't).
    Create credentials: https://console.hetzner.com → Object Storage → Access Keys
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

variable "s3_secret_key" {
  description = "Hetzner Object Storage secret key"
  type        = string
  default     = ""
  sensitive   = true
}

# ── Data volume ───────────────────────────────────────────────────────────────

variable "data_volume_size" {
  description = "Size in GB of the data volume mounted at /var/lib/fleet. Can be increased later, never decreased."
  type        = number
  default     = 20

  validation {
    condition     = var.data_volume_size >= 10 && var.data_volume_size <= 10240 && floor(var.data_volume_size) == var.data_volume_size
    error_message = "data_volume_size must be a whole number of GB between 10 and 10240 (Hetzner limits)."
  }
}

# ── Protection ────────────────────────────────────────────────────────────────

variable "protect_resources" {
  description = <<-EOT
    Enable Hetzner delete and rebuild protection on the server and
    delete protection on the data volume. While true,
    `tofu destroy` and server replacement fail. To tear down: set to false,
    run `tofu apply`, then `tofu destroy`.
  EOT
  type        = bool
  default     = true
}

variable "server_backups" {
  description = <<-EOT
    Enable Hetzner automated daily backups of the server disk (7 retained).
    Costs about 20% of the server price. They cover the OS and config only,
    not the data volume at /var/lib/fleet.
  EOT
  type        = bool
  default     = false
}

# ── Off-host backups (restic) ─────────────────────────────────────────────────
# Leave backup_repository empty to disable. Backup settings are written by
# cloud-init at server creation; see README "Backups" for changing them later.

variable "backup_repository" {
  description = <<-EOT
    restic repository for nightly MySQL + /etc/fleet backups. Use Object
    Storage in a different location from the server, for example
    "s3:https://hel1.your-objectstorage.com/my-fleet-backups/fleet".
    Empty disables backups.
  EOT
  type        = string
  default     = ""
}

variable "backup_access_key" {
  description = "Access key for the backup bucket. Use credentials separate from s3_access_key."
  type        = string
  default     = ""
  sensitive   = true

  validation {
    condition     = var.backup_repository == "" || var.backup_access_key != ""
    error_message = "backup_access_key is required when backup_repository is set."
  }
}

variable "backup_secret_key" {
  description = "Secret key for the backup bucket."
  type        = string
  default     = ""
  sensitive   = true

  validation {
    condition     = var.backup_repository == "" || var.backup_secret_key != ""
    error_message = "backup_secret_key is required when backup_repository is set."
  }
}

variable "backup_password" {
  description = <<-EOT
    restic repository password (min 16 chars). Keep it in a password manager,
    separate from the state: with it and the bucket keys you can restore even
    if the state is lost. Losing it makes the backups unreadable.
  EOT
  type        = string
  default     = ""
  sensitive   = true

  validation {
    condition     = var.backup_repository == "" || length(var.backup_password) >= 16
    error_message = "backup_password must be at least 16 characters when backup_repository is set."
  }
}

variable "backup_keep_daily" {
  description = "Daily snapshots to keep."
  type        = number
  default     = 7
}

variable "backup_keep_weekly" {
  description = "Weekly snapshots to keep."
  type        = number
  default     = 4
}

variable "backup_keep_monthly" {
  description = "Monthly snapshots to keep."
  type        = number
  default     = 6
}

variable "backup_healthcheck_url" {
  description = <<-EOT
    Optional dead-man's-switch ping URL (healthchecks.io, Uptime Kuma push, …).
    Pinged on start (/start), success, and failure (/fail). Configure the check
    to expect a daily ping so a missed run alerts too. Empty disables it.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

variable "restic_version" {
  description = "restic Docker image tag. Pin to an exact version."
  type        = string
  default     = "0.18.0"
}
