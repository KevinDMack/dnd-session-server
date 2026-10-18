locals {
  media_storage_account_name = "jf${substr(sha256("${var.subscription_id}/${azurerm_resource_group.jellyfin.name}"), 0, 20)}"
  media_endpoint             = "${local.media_storage_account_name}.file.core.windows.net"
}

resource "azurerm_user_assigned_identity" "media" {
  name                = "${var.name_prefix}-media"
  location            = azurerm_resource_group.jellyfin.location
  resource_group_name = azurerm_resource_group.jellyfin.name
}

# AzureRM 4.50 has no SMB OAuth field. Own the entire account through ARM,
# rather than two providers competing over its authentication configuration.
resource "azapi_resource" "media" {
  type      = "Microsoft.Storage/storageAccounts@2025-08-01"
  name      = local.media_storage_account_name
  parent_id = azurerm_resource_group.jellyfin.id
  location  = azurerm_resource_group.jellyfin.location
  body = {
    kind = "StorageV2"
    sku  = { name = "Standard_LRS" }
    properties = {
      minimumTlsVersion        = "TLS1_2"
      supportsHttpsTrafficOnly = true
      allowBlobPublicAccess    = false
      # Azure Backup requires this. The VM never receives keys or listKeys.
      allowSharedKeyAccess = true
      publicNetworkAccess  = "Enabled"
      azureFilesIdentityBasedAuthentication = {
        directoryServiceOptions = "None"
        smbOAuthSettings = {
          isSmbOAuthEnabled = true
        }
      }
      networkAcls = {
        defaultAction = "Deny"
        bypass        = "AzureServices"
        virtualNetworkRules = [{
          id     = azurerm_subnet.jellyfin.id
          action = "Allow"
        }]
        ipRules = []
      }
    }
  }
  response_export_values = []

  lifecycle {
    prevent_destroy = true
  }
}

# storage_account_id selects the ARM control plane, not Shared Key data APIs.
resource "azurerm_storage_share" "media" {
  name               = "media"
  storage_account_id = azapi_resource.media.id
  quota              = var.media_share_quota_gb
  enabled_protocol   = "SMB"
  access_tier        = "Hot"

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_role_assignment" "media" {
  scope                = azapi_resource.media.id
  role_definition_name = "Storage File Data SMB MI Admin"
  principal_id         = azurerm_user_assigned_identity.media.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_backup_container_storage_account" "media" {
  resource_group_name = azurerm_resource_group.jellyfin.name
  recovery_vault_name = azurerm_recovery_services_vault.jellyfin.name
  storage_account_id  = azapi_resource.media.id
}

resource "azurerm_backup_policy_file_share" "media" {
  name                = "${var.name_prefix}-media-daily"
  resource_group_name = azurerm_resource_group.jellyfin.name
  recovery_vault_name = azurerm_recovery_services_vault.jellyfin.name
  timezone            = "UTC"

  backup {
    frequency = "Daily"
    time      = "03:30"
  }
  retention_daily {
    count = var.backup_retention_days
  }
}

resource "azurerm_backup_protected_file_share" "media" {
  resource_group_name       = azurerm_resource_group.jellyfin.name
  recovery_vault_name       = azurerm_recovery_services_vault.jellyfin.name
  source_storage_account_id = azurerm_backup_container_storage_account.media.storage_account_id
  source_file_share_name    = azurerm_storage_share.media.name
  backup_policy_id          = azurerm_backup_policy_file_share.media.id

  lifecycle {
    prevent_destroy = true
  }
}
