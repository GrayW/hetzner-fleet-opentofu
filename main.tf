terraform {
  required_version = ">= 1.9"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.49"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
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
  alias      = "hetzner_s3"
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
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = ["0.0.0.0/0", "::/0"]
    description = "SSH"
  }
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "80"
    source_ips = ["0.0.0.0/0", "::/0"]
    description = "HTTP — required for ACME challenges"
  }
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "443"
    source_ips = ["0.0.0.0/0", "::/0"]
    description = "HTTPS"
  }
  rule {
    direction  = "in"
    protocol   = "icmp"
    source_ips = ["0.0.0.0/0", "::/0"]
    description = "ICMP ping"
  }
}

# ── Object Storage ────────────────────────────────────────────────────────────

locals {
  s3_configured = var.s3_access_key != ""
  s3_bucket     = "${var.server_name}-packages"
  s3_endpoint   = "https://${var.location}.your-objectstorage.com"

  cloud_init = templatefile("${path.module}/cloud-init.tftpl", {
    mysql_pw      = random_password.mysql.result
    mysql_root_pw = random_password.mysql_root.result
    fleet_jwt     = random_password.fleet_jwt.result
    enroll_secret      = random_bytes.enroll_secret.hex
    fleet_version      = var.fleet_version
    fleet_license_key  = var.fleet_license_key
    server_private_key = random_bytes.server_private_key.hex
    wstep_cert         = tls_self_signed_cert.wstep.cert_pem
    wstep_key          = tls_private_key.wstep.private_key_pem
    domain             = var.domain
    admin_email        = var.admin_email
    s3_configured = local.s3_configured
    s3_bucket     = local.s3_bucket
    s3_access_key = var.s3_access_key
    s3_secret_key = var.s3_secret_key
    s3_endpoint   = local.s3_endpoint
    s3_region     = var.location
  })
}

resource "aws_s3_bucket" "fleet_packages" {
  count    = local.s3_configured ? 1 : 0
  provider = aws.hetzner_s3
  bucket   = local.s3_bucket
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

  # Explicitly enable both stacks — Hetzner assigns a /32 IPv4 and a /64 IPv6.
  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  # Server replacement destroys persistent data (MariaDB volumes).
  # For deliberate replacement: tofu taint hcloud_server.fleet
  lifecycle {
    ignore_changes = [user_data] # re-apply doesn't re-run cloud-init
  }
}
