output "server_id" {
  description = "Hetzner server ID"
  value       = hcloud_server.fleet.id
}

output "server_type" {
  description = "Deployed server type"
  value       = hcloud_server.fleet.server_type
}

output "location" {
  description = "Deployed location"
  value       = hcloud_server.fleet.location
}

output "ipv4_address" {
  description = "Server IPv4 address — add DNS A record pointing your domain here"
  value       = hcloud_server.fleet.ipv4_address
}

output "ipv6_address" {
  description = "Server IPv6 address (first host in the /64 block) — add DNS AAAA record"
  value       = hcloud_server.fleet.ipv6_address
}

output "ssh_command" {
  description = "SSH command using the generated key"
  value       = "ssh -i ${path.module}/.fleet_ed25519 root@${hcloud_server.fleet.ipv4_address}"
}

output "fleet_url" {
  description = "Fleet MDM URL — DNS must resolve before TLS cert can be issued"
  value       = "https://${var.domain}"
}

output "enroll_secret" {
  description = "osquery enroll secret — retrieve with: tofu output -raw enroll_secret"
  value       = random_bytes.enroll_secret.hex
  sensitive   = true
}

output "wstep_cert" {
  description = "Windows MDM WSTEP CA certificate (PEM) — back this up; losing it breaks Windows MDM re-enrollment"
  value       = tls_self_signed_cert.wstep.cert_pem
}

output "s3_bucket" {
  description = "S3 bucket name for Fleet software packages"
  value       = local.s3_bucket
}

output "s3_endpoint" {
  description = "Hetzner Object Storage endpoint for the chosen location"
  value       = local.s3_endpoint
}

output "dns_records" {
  description = "DNS records to create before Fleet will be reachable over HTTPS"
  value = {
    A    = "${var.domain}  →  ${hcloud_server.fleet.ipv4_address}"
    AAAA = "${var.domain}  →  ${hcloud_server.fleet.ipv6_address}"
  }
}

output "next_steps" {
  description = "Post-deploy checklist"
  value       = <<-EOT

    ── After apply ──────────────────────────────────────────────
    1. Add DNS A record:    ${var.domain} → ${hcloud_server.fleet.ipv4_address}
       Add DNS AAAA record: ${var.domain} → ${hcloud_server.fleet.ipv6_address}
    2. Wait ~5 min for cloud-init (package upgrade + image pulls)
    3. Wait ~2 min for Caddy to obtain a TLS cert via Let's Encrypt
    4. Open https://${var.domain} to create the Fleet admin account
    5. Retrieve enroll secret:
         tofu output -raw enroll_secret
    6. Monitor cloud-init:
         ssh -i .fleet_ed25519 root@${hcloud_server.fleet.ipv4_address} 'cloud-init status --wait'
    7. Fleet logs:
         ssh -i .fleet_ed25519 root@${hcloud_server.fleet.ipv4_address} 'podman logs -f fleet-server'
  EOT
}
