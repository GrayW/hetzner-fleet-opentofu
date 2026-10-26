terraform {
  required_version = ">= 1.9"

  # State and plan files hold every secret this config generates, so both are
  # encrypted with a key derived from var.state_passphrase. Unencrypted state is
  # refused; to migrate an existing one, see docs/upgrade-0.2.md.
  encryption {
    key_provider "pbkdf2" "main" {
      passphrase = var.state_passphrase
    }
    method "aes_gcm" "main" {
      keys = key_provider.pbkdf2.main
    }
    state {
      method   = method.aes_gcm.main
      enforced = true
    }
    plan {
      method   = method.aes_gcm.main
      enforced = true
    }
  }

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.70" # hcloud_primary_ip.location
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.69"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

provider "hcloud" {
  token = var.hetzner_token
}

# AWS provider configured for Hetzner Object Storage (S3-compatible API).
# The endpoint is location-specific; "us-east-1" is accepted as the region
# by Hetzner for SDK compatibility — the endpoint URL controls the actual DC.
# Placeholder credentials are used when S3 is not configured so provider
# init doesn't fail; no API calls are made in that case (count = 0 resources).
provider "aws" {
  alias = "hetzner_s3"
  # Hetzner S3 region must equal the datacenter location name (nbg1, fsn1, hel1…)
  region     = var.location
  access_key = var.s3_access_key != "" ? var.s3_access_key : "placeholder"
  secret_key = var.s3_secret_key != "" ? var.s3_secret_key : "placeholder"

  endpoints {
    s3 = "https://${var.location}.your-objectstorage.com"
  }

  # Suppress AWS-specific checks that don't apply to Hetzner
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_region_validation      = true
  s3_use_path_style           = true
}

# ── Secrets (stored in state; use `tofu output -raw` to retrieve) ─────────────

resource "random_password" "mysql" {
  length  = 32
  special = false
}

resource "random_password" "mysql_root" {
  length  = 32
  special = false
}

resource "random_password" "fleet_jwt" {
  length  = 48
  special = false
}

# Enroll secret is a 64-char hex string written into cloud-init
# rather than generated on the server, so we know it before first connect.
resource "random_bytes" "enroll_secret" {
  length = 32
}

# ── SSH key ───────────────────────────────────────────────────────────────────

resource "tls_private_key" "fleet" {
  algorithm = "ED25519"
}

# ── Apple MDM server private key ──────────────────────────────────────────────
# Fleet requires a random symmetric secret (≥32 bytes) injected via
# FLEET_SERVER_PRIVATE_KEY. It is NOT an RSA key — equivalent to:
#   openssl rand -hex 48

resource "random_bytes" "server_private_key" {
  length = 48 # 48 raw bytes → 96-char hex string, well above the 32-byte minimum
}

# ── Windows MDM WSTEP certificate ─────────────────────────────────────────────
# Fleet requires a CA cert+key pair for the Windows Simple Certificate
# Enrollment Protocol (WSTEP). Equivalent to:
#   openssl genrsa --traditional -out wstep.key 4096
#   openssl req -x509 -new -nodes -key wstep.key -sha256 -days 3652 \
#     -out wstep.crt -subj '/CN=Fleet Root CA/C=US/O=Fleet.'

resource "tls_private_key" "wstep" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_self_signed_cert" "wstep" {
  private_key_pem = tls_private_key.wstep.private_key_pem

  subject {
    common_name  = "Fleet Root CA"
    country      = "US"
    organization = "Fleet."
  }

  validity_period_hours = 87648 # 3652 days

  is_ca_certificate = true

  allowed_uses = [
    "cert_signing",
    "digital_signature",
    "key_encipherment",
  ]
}

resource "hcloud_ssh_key" "fleet" {
  name       = "${var.server_name}-key"
  public_key = tls_private_key.fleet.public_key_openssh
}

# Write the private key next to the .tf files so SSH and post-apply
# commands work without further setup.
resource "local_sensitive_file" "fleet_ssh_private_key" {
  content         = tls_private_key.fleet.private_key_openssh
  filename        = "${path.module}/.fleet_ed25519"
  file_permission = "0600"
}

# ── Firewall ──────────────────────────────────────────────────────────────────

resource "hcloud_firewall" "fleet" {
  name = "${var.server_name}-fw"

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "22"
    source_ips  = var.admin_cidrs
    description = "SSH"
  }
  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "80"
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "HTTP — required for ACME challenges"
  }
  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "443"
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "HTTPS"
  }
  rule {
    direction   = "in"
    protocol    = "icmp"
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "ICMP ping"
  }
}

# ── Object Storage ────────────────────────────────────────────────────────────

locals {
  s3_configured = var.s3_access_key != ""
  # Off-host backups are opt-in; see variables.tf.
  backup_enabled = var.backup_repository != ""
  s3_bucket      = "${var.server_name}-packages"
  s3_endpoint    = "https://${var.location}.your-objectstorage.com"

  cloud_init = templatefile("${path.module}/cloud-init.tftpl", {
    mysql_pw           = random_password.mysql.result
    mysql_root_pw      = random_password.mysql_root.result
    fleet_jwt          = random_password.fleet_jwt.result
    enroll_secret      = random_bytes.enroll_secret.hex
    fleet_version      = var.fleet_version
    mysql_version      = var.mysql_version
    redis_version      = var.redis_version
    fleet_license_key  = var.fleet_license_key
    server_private_key = random_bytes.server_private_key.hex
    wstep_cert         = tls_self_signed_cert.wstep.cert_pem
    wstep_key          = tls_private_key.wstep.private_key_pem
    domain             = var.domain
    admin_email        = var.admin_email
    s3_configured      = local.s3_configured
    s3_bucket          = local.s3_bucket
    s3_access_key      = var.s3_access_key
    s3_secret_key      = var.s3_secret_key
    s3_endpoint        = local.s3_endpoint
    s3_region          = var.location
    data_volume_id     = hcloud_volume.fleet_data.id
    backup_enabled     = local.backup_enabled
    backup_repository  = var.backup_repository
    backup_access_key  = var.backup_access_key
    backup_secret_key  = var.backup_secret_key
    backup_password    = var.backup_password
    backup_keep        = "--keep-daily ${var.backup_keep_daily} --keep-weekly ${var.backup_keep_weekly} --keep-monthly ${var.backup_keep_monthly}"
    backup_hc_url      = var.backup_healthcheck_url
    restic_version     = var.restic_version
    server_name        = var.server_name
  })
}

resource "aws_s3_bucket" "fleet_packages" {
  count    = local.s3_configured ? 1 : 0
  provider = aws.hetzner_s3
  bucket   = local.s3_bucket
}

# ── Data volume ───────────────────────────────────────────────────────────────
# Holds everything under /var/lib/fleet (MySQL, Redis, Caddy certs, vulndb) so
# data survives server replacement. Hetzner formats it once at creation;
# cloud-init only mounts it and never runs mkfs, so a reattached volume is safe.

resource "hcloud_volume" "fleet_data" {
  name              = "${var.server_name}-data"
  size              = var.data_volume_size
  location          = var.location
  format            = "ext4"
  delete_protection = var.protect_resources
}

# ── Primary IPs ───────────────────────────────────────────────────────────────
# Explicit Primary IPs outlive the server (auto_delete = false), so a
# replacement server keeps the same addresses and DNS doesn't change.
# Assignment is set on the server side (public_net) to avoid a dependency cycle.

resource "hcloud_primary_ip" "ipv4" {
  name              = "${var.server_name}-ipv4"
  type              = "ipv4"
  location          = var.location
  auto_delete       = false
  delete_protection = var.protect_resources
}

resource "hcloud_primary_ip" "ipv6" {
  name              = "${var.server_name}-ipv6"
  type              = "ipv6"
  location          = var.location
  auto_delete       = false
  delete_protection = var.protect_resources
}

# Backups next to the server don't survive the loss of that location.
check "backup_location" {
  assert {
    condition     = !strcontains(var.backup_repository, "${var.location}.your-objectstorage.com")
    error_message = "backup_repository is in the same location as the server (${var.location}). Use Object Storage in a different location."
  }
}

# ── Image ─────────────────────────────────────────────────────────────────────

data "hcloud_image" "opensuse_leap" {
  name        = var.image_name
  most_recent = true
}

# ── Server ────────────────────────────────────────────────────────────────────

resource "hcloud_server" "fleet" {
  name         = var.server_name
  server_type  = var.server_type
  image        = data.hcloud_image.opensuse_leap.name
  location     = var.location
  ssh_keys     = [hcloud_ssh_key.fleet.id]
  firewall_ids = [hcloud_firewall.fleet.id]
  user_data    = local.cloud_init

  # Hetzner-side protection: the API refuses delete/rebuild while enabled, so
  # `tofu destroy` and replacement both fail. Hetzner requires both flags to match.
  delete_protection  = var.protect_resources
  rebuild_protection = var.protect_resources

  # Hetzner daily disk snapshots (7 kept, ~20% of server price). Secondary net:
  # they don't cover the data volume; off-host MySQL backups are the primary.
  backups = var.server_backups

  # Both stacks, on the persistent Primary IPs: a /32 IPv4 and a /64 IPv6.
  public_net {
    ipv4_enabled = true
    ipv4         = hcloud_primary_ip.ipv4.id
    ipv6_enabled = true
    ipv6         = hcloud_primary_ip.ipv6.id
  }

  # Persistent data lives on hcloud_volume.fleet_data, which is reattached to
  # a replacement server. For deliberate replacement: set
  # protect_resources = false, apply, then tofu taint hcloud_server.fleet
  lifecycle {
    ignore_changes = [user_data] # re-apply doesn't re-run cloud-init
  }
}

# Attached after the server exists; cloud-init waits for the device to appear.
# automount stays off because cloud-init owns the fstab entry.
resource "hcloud_volume_attachment" "fleet_data" {
  volume_id = hcloud_volume.fleet_data.id
  server_id = hcloud_server.fleet.id
  automount = false
}
