locals {
  resource_group_name = coalesce(var.resource_group_name, "rg-${var.name_prefix}")
  # Storage account and container registry names must be globally unique and alphanumeric.
  storage_account_name = substr("st${var.name_prefix}${random_string.suffix.result}", 0, 24)
  registry_name        = substr("cr${var.name_prefix}${random_string.suffix.result}", 0, 50)
  tags                 = var.tags
}

resource "random_string" "suffix" {
  length  = 6
  lower   = true
  upper   = false
  numeric = true
  special = false
}

resource "azurerm_resource_group" "this" {
  name     = local.resource_group_name
  location = var.location
  tags     = local.tags
}

# Identity used by Jellyfin to pull its image and to read/write the media blobs.
resource "azurerm_user_assigned_identity" "jellyfin" {
  name                = "id-${var.name_prefix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = local.tags
}

resource "azurerm_storage_account" "this" {
  name                            = local.storage_account_name
  resource_group_name             = azurerm_resource_group.this.name
  location                        = azurerm_resource_group.this.location
  account_tier                    = "Standard"
  account_kind                    = "StorageV2"
  account_replication_type        = "LRS"
  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  tags                            = local.tags
}

# Video files. Accessed from the container with BlobFuse2 + managed identity.
resource "azurerm_storage_container" "media" {
  name                  = var.media_container_name
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"
}

# Jellyfin /config (database, metadata, settings) persisted on Azure Files.
resource "azurerm_storage_share" "config" {
  name               = var.config_share_name
  storage_account_id = azurerm_storage_account.this.id
  quota              = var.config_share_quota_gb
}

resource "azurerm_role_assignment" "blob_data_contributor" {
  scope                = azurerm_storage_account.this.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.jellyfin.principal_id
}

resource "azurerm_role_assignment" "file_data_contributor" {
  scope                = azurerm_storage_account.this.id
  role_definition_name = "Storage File Data SMB Share Contributor"
  principal_id         = azurerm_user_assigned_identity.jellyfin.principal_id
}

resource "azurerm_container_registry" "this" {
  name                = local.registry_name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "Basic"
  admin_enabled       = false
  tags                = local.tags
}

resource "azurerm_role_assignment" "acr_pull" {
  scope                = azurerm_container_registry.this.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.jellyfin.principal_id
}

resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-${var.name_prefix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days
  tags                = local.tags
}

resource "azurerm_container_app_environment" "this" {
  name                       = "cae-${var.name_prefix}"
  resource_group_name        = azurerm_resource_group.this.name
  location                   = azurerm_resource_group.this.location
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
  tags                       = local.tags
}

# Azure Files share made available to the container app as a volume.
resource "azurerm_container_app_environment_storage" "config" {
  name                         = "jellyfin-config"
  container_app_environment_id = azurerm_container_app_environment.this.id
  account_name                 = azurerm_storage_account.this.name
  share_name                   = azurerm_storage_share.config.name
  access_key                   = azurerm_storage_account.this.primary_access_key
  access_mode                  = "ReadWrite"
}

resource "azurerm_container_app" "jellyfin" {
  name                         = "ca-${var.name_prefix}"
  resource_group_name          = azurerm_resource_group.this.name
  container_app_environment_id = azurerm_container_app_environment.this.id
  revision_mode                = "Single"
  tags                         = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.jellyfin.id]
  }

  registry {
    server   = azurerm_container_registry.this.login_server
    identity = azurerm_user_assigned_identity.jellyfin.id
  }

  ingress {
    external_enabled = true
    target_port      = 8096
    transport        = "auto"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = var.min_replicas
    max_replicas = var.max_replicas

    container {
      name   = "jellyfin"
      image  = "${azurerm_container_registry.this.login_server}/${var.container_image}"
      cpu    = var.cpu
      memory = var.memory

      # Consumed by the image entrypoint to mount the blob container with BlobFuse2.
      env {
        name  = "AZURE_CLIENT_ID"
        value = azurerm_user_assigned_identity.jellyfin.client_id
      }

      env {
        name  = "STORAGE_ACCOUNT_NAME"
        value = azurerm_storage_account.this.name
      }

      env {
        name  = "MEDIA_CONTAINER_NAME"
        value = azurerm_storage_container.media.name
      }

      env {
        name  = "MEDIA_MOUNT_PATH"
        value = var.media_mount_path
      }

      env {
        name  = "JELLYFIN_CONFIG_DIR"
        value = "/config/config"
      }

      env {
        name  = "JELLYFIN_DATA_DIR"
        value = "/config/data"
      }

      env {
        name  = "JELLYFIN_CACHE_DIR"
        value = "/config/cache"
      }

      volume_mounts {
        name = "config"
        path = "/config"
      }
    }

    volume {
      name         = "config"
      storage_name = azurerm_container_app_environment_storage.config.name
      storage_type = "AzureFile"
    }
  }

  depends_on = [
    azurerm_role_assignment.acr_pull,
    azurerm_role_assignment.blob_data_contributor
  ]
}
