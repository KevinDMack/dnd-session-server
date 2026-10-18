output "public_ip" {
  description = "Create the domain's public DNS A record with this static address."
  value       = azurerm_public_ip.jellyfin.ip_address
}

output "fqdn" {
  value = var.domain_name
}

output "jellyfin_url" {
  value = "https://${var.domain_name}"
}

output "vm_name" {
  value = azurerm_linux_virtual_machine.jellyfin.name
}

output "resource_group_name" {
  value = azurerm_resource_group.jellyfin.name
}

output "ssh_command" {
  description = "Add -i /path/to/private_key if your key is not loaded in your SSH agent."
  value       = "ssh ${var.admin_username}@${azurerm_public_ip.jellyfin.ip_address}"
}

output "backup_vault_name" {
  value = azurerm_recovery_services_vault.jellyfin.name
}

output "monthly_budget" {
  value = {
    name       = azurerm_consumption_budget_resource_group.jellyfin.name
    amount     = var.monthly_budget_amount
    start_date = var.budget_start_date
    currency   = "subscription billing currency"
  }
}

output "https_allowed_cidrs" {
  description = "Application allowlist enforced by Caddy; public 443 is still open for ACME."
  value       = local.https_cidrs
}

output "media_storage_account_name" {
  value = azapi_resource.media.name
}

output "media_share_name" {
  value = azurerm_storage_share.media.name
}

output "media_smb_path" {
  value = "//${local.media_endpoint}/${azurerm_storage_share.media.name}"
}

output "media_identity_client_id" {
  description = "Public client ID used by azfilesauthmanager; not a secret."
  value       = azurerm_user_assigned_identity.media.client_id
}
