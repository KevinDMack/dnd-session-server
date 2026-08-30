variable "subscription_id" {
  description = "Azure subscription ID the infrastructure is deployed into."
  type        = string
}

variable "name_prefix" {
  description = "Prefix used when naming the Azure resources. Lower case letters and numbers only."
  type        = string
  default     = "jellyfin"

  validation {
    condition     = can(regex("^[a-z0-9]{3,12}$", var.name_prefix))
    error_message = "name_prefix must be 3-12 characters of lower case letters and numbers."
  }
}

variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "eastus"
}

variable "resource_group_name" {
  description = "Name of the resource group to create. Defaults to \"rg-<name_prefix>\"."
  type        = string
  default     = null
}

variable "media_container_name" {
  description = "Name of the blob container that stores the video files."
  type        = string
  default     = "media"
}

variable "config_share_name" {
  description = "Name of the Azure Files share that persists the Jellyfin /config directory."
  type        = string
  default     = "jellyfin-config"
}

variable "config_share_quota_gb" {
  description = "Size (GiB) of the Azure Files share used for /config."
  type        = number
  default     = 100
}

variable "media_mount_path" {
  description = "Path inside the container where the blob container is mounted by BlobFuse2."
  type        = string
  default     = "/media"
}

variable "container_image" {
  description = "Image (repository:tag) to run. The image is expected to exist in the created container registry."
  type        = string
  default     = "jellyfin-blobfuse:latest"
}

variable "cpu" {
  description = "vCPU allocated to the Jellyfin container."
  type        = number
  default     = 2
}

variable "memory" {
  description = "Memory allocated to the Jellyfin container, for example \"4Gi\"."
  type        = string
  default     = "4Gi"
}

variable "min_replicas" {
  description = "Minimum number of replicas. Jellyfin is stateful, keep this at 1 to avoid cold starts."
  type        = number
  default     = 1
}

variable "max_replicas" {
  description = "Maximum number of replicas. Jellyfin must not scale beyond a single instance."
  type        = number
  default     = 1

  validation {
    condition     = var.max_replicas == 1
    error_message = "Jellyfin shares a single /config volume, so max_replicas must be 1."
  }
}

variable "log_retention_days" {
  description = "Retention in days for the Log Analytics workspace backing the Container Apps environment."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
