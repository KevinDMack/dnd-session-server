output "resource_group_name" {
  description = "Name of the resource group holding the deployment."
  value       = azurerm_resource_group.this.name
}

output "storage_account_name" {
  description = "Storage account holding the media blob container and the /config file share."
  value       = azurerm_storage_account.this.name
}

output "media_container_name" {
  description = "Blob container mounted with BlobFuse2 for the video files."
  value       = azurerm_storage_container.media.name
}

output "config_share_name" {
  description = "Azure Files share mounted at /config in the Jellyfin container."
  value       = azurerm_storage_share.config.name
}

output "container_registry_login_server" {
  description = "Login server of the container registry hosting the Jellyfin image."
  value       = azurerm_container_registry.this.login_server
}

output "container_registry_name" {
  description = "Name of the container registry, for use with \"az acr build\"."
  value       = azurerm_container_registry.this.name
}

output "managed_identity_client_id" {
  description = "Client ID of the user assigned managed identity used by Jellyfin."
  value       = azurerm_user_assigned_identity.jellyfin.client_id
}

output "container_app_name" {
  description = "Name of the Jellyfin container app."
  value       = azurerm_container_app.jellyfin.name
}

output "jellyfin_url" {
  description = "Public URL of the Jellyfin instance."
  value       = "https://${azurerm_container_app.jellyfin.ingress[0].fqdn}"
}
