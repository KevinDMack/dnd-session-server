output "public_ip" {
  description = "Stable IPv4 address; create the domain's public DNS A record pointing here."
  value       = aws_eip.jellyfin.public_ip
}

output "jellyfin_url" {
  description = "HTTPS endpoint after DNS and automatic certificate issuance succeed."
  value       = "https://${var.domain_name}"
}

output "ssh_command" {
  description = "SSH as Ubuntu UID/GID 1000 using the private key corresponding to ssh_public_key."
  value       = "ssh ubuntu@${aws_eip.jellyfin.public_ip}"
}

output "instance_id" {
  value = aws_instance.jellyfin.id
}

output "availability_zone" {
  value = local.availability_zone
}

output "instance_role_arn" {
  value = aws_iam_role.jellyfin.arn
}

output "media_storage_type" {
  value = var.media_storage_type
}

output "media_volume_id" {
  description = "Independent retained EBS media volume; null for EFS."
  value       = try(aws_ebs_volume.media[0].id, null)
}

output "efs_file_system_id" {
  value = try(aws_efs_file_system.media[0].id, null)
}

output "efs_access_point_id" {
  value = try(aws_efs_access_point.media[0].id, null)
}

output "backup_vault_name" {
  value = aws_backup_vault.jellyfin.name
}

output "backup_plan_id" {
  value = aws_backup_plan.jellyfin.id
}

output "https_allowed_cidrs" {
  description = "Effective application allowlist enforced by Caddy."
  value       = local.https_cidrs
}
