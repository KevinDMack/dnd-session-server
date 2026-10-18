terraform {
  required_version = ">= 1.9.0, < 2.0.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "= 4.50.0"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "= 2.13.0"
    }
  }
}

provider "azapi" {
  subscription_id = var.subscription_id
}

provider "azurerm" {
  subscription_id = var.subscription_id

  features {
    resource_group {
      prevent_deletion_if_contains_resources = true
    }
    recovery_service {
      vm_backup_stop_protection_and_retain_data_on_destroy = true
      purge_protected_items_from_vault_on_destroy          = false
    }
  }
}
