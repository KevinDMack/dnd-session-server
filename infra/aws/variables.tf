variable "region" {
  description = "AWS region; authenticate using the normal AWS credential chain, never tfvars credentials."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Distinct resource name prefix for this deployment."
  type        = string
  default     = "jellyfin"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,22}[a-z0-9]$", var.name_prefix))
    error_message = "Use 3-24 lowercase letters, digits or hyphens, starting with a letter and ending alphanumeric."
  }
}

variable "availability_zone" {
  description = "Optional AZ in the selected region. The VM, EBS media and EFS mount target share this AZ."
  type        = string
  default     = null
}

variable "administrator_cidr" {
  description = "Required trusted public IPv4 CIDR for SSH; prefer your fixed public IP/32."
  type        = string
  validation {
    condition     = can(cidrnetmask(var.administrator_cidr)) && can(regex("^[0-9./]+$", var.administrator_cidr)) && try(tonumber(split("/", var.administrator_cidr)[1]) >= 8, false)
    error_message = "Use an IPv4 CIDR with prefix /8 or narrower; unrestricted SSH is forbidden."
  }
}

variable "ssh_public_key" {
  description = "Single-line OpenSSH Ed25519 or RSA public key for the Ubuntu administrator (ubuntu, UID/GID 1000); never a private key."
  type        = string
  validation {
    condition     = can(regex("^(ssh-ed25519|ssh-rsa) [A-Za-z0-9+/]+={0,3}( [A-Za-z0-9@._-]+)?$", var.ssh_public_key))
    error_message = "Provide a single-line ssh-ed25519 or ssh-rsa public key."
  }
}

variable "domain_name" {
  description = "Public DNS hostname; point its A record to public_ip and remove conflicting AAAA records before ACME issuance."
  type        = string
  validation {
    condition     = length(var.domain_name) <= 253 && can(regex("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}$", var.domain_name))
    error_message = "Use a lowercase public DNS hostname without scheme, port, wildcard or trailing dot."
  }
}

variable "https_allowed_cidrs" {
  description = "Caddy application IPv4 allowlist; null defaults to administrator_cidr. Public TCP 443 is required for ACME TLS-ALPN. Use [\"0.0.0.0/0\"] only after securing Jellyfin's setup wizard."
  type        = list(string)
  default     = null
  validation {
    condition     = var.https_allowed_cidrs == null ? true : length(var.https_allowed_cidrs) > 0 && alltrue([for cidr in var.https_allowed_cidrs : can(cidrnetmask(cidr)) && can(regex("^[0-9./]+$", cidr))])
    error_message = "Provide null or a nonempty list of valid IPv4 CIDRs."
  }
}

variable "os_disk_size_gb" {
  description = "Encrypted gp3 root volume containing Ubuntu, Jellyfin configuration and Caddy certificates; retained on instance termination."
  type        = number
  default     = 64
  validation {
    condition     = var.os_disk_size_gb >= 64 && var.os_disk_size_gb <= 16384 && floor(var.os_disk_size_gb) == var.os_disk_size_gb
    error_message = "Use an integer from 64 to 16384 GiB."
  }
}

variable "media_storage_type" {
  description = "Media backend: independent encrypted EBS gp3 volume (default), or encrypted IAM/TLS-authenticated EFS."
  type        = string
  default     = "ebs"
  validation {
    condition     = contains(["ebs", "efs"], var.media_storage_type)
    error_message = "media_storage_type must be ebs or efs."
  }
}

variable "media_volume_size_gb" {
  description = "EBS media volume capacity in GiB; unused for EFS, which grows with stored data."
  type        = number
  default     = 512
  validation {
    condition     = var.media_volume_size_gb >= 1 && var.media_volume_size_gb <= 16384 && floor(var.media_volume_size_gb) == var.media_volume_size_gb
    error_message = "Use an integer from 1 to 16384 GiB."
  }
}

variable "efs_one_zone" {
  description = "Opt into lower-resilience EFS One Zone in the VM's AZ. Default false uses regional EFS."
  type        = bool
  default     = false
}

variable "backup_retention_days" {
  description = "Daily EC2/config and explicitly selected media backup retention in days."
  type        = number
  default     = 30
  validation {
    condition     = var.backup_retention_days >= 7 && var.backup_retention_days <= 36500 && floor(var.backup_retention_days) == var.backup_retention_days
    error_message = "Use an integer from 7 to 36500 days."
  }
}

variable "monthly_budget_amount" {
  description = "Monthly account-wide USD alert budget, not a spending cap. Includes costs outside this deployment."
  type        = number
  default     = 100
  validation {
    condition     = var.monthly_budget_amount > 0
    error_message = "The monthly budget must be positive."
  }
}

variable "budget_contact_emails" {
  description = "One to ten recipients for 80% and 100% actual-spend email alerts."
  type        = list(string)
  validation {
    condition     = length(var.budget_contact_emails) >= 1 && length(var.budget_contact_emails) <= 10 && alltrue([for email in var.budget_contact_emails : can(regex("^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$", email))])
    error_message = "Provide one to ten valid email addresses."
  }
}
