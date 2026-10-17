variable "subscription_id" {
  description = "Azure subscription UUID. Authenticate separately with Azure CLI or ARM_* environment variables."
  type        = string
  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.subscription_id))
    error_message = "subscription_id must be a UUID."
  }
}

variable "name_prefix" {
  description = "Lowercase resource name prefix; use a distinct prefix for each deployment."
  type        = string
  default     = "jellyfin"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,22}[a-z0-9]$", var.name_prefix))
    error_message = "Use 3-24 lowercase alphanumeric/hyphen characters, starting with a letter and ending alphanumeric."
  }
}

variable "location" {
  type        = string
  description = "Azure region."
  default     = "eastus"
  validation {
    condition     = can(regex("^[a-z0-9]+$", var.location))
    error_message = "Use an Azure region identifier such as eastus."
  }
}

variable "vm_size" {
  type        = string
  description = "VM SKU; Standard_B2s is intended for direct play, not demanding software transcoding."
  default     = "Standard_B2s"
  validation {
    condition     = can(regex("^Standard_[A-Za-z0-9_]+$", var.vm_size))
    error_message = "Use a Standard_* Azure VM SKU."
  }
}

variable "admin_username" {
  type        = string
  description = "SSH administrator; UID/GID 1000 also owns Jellyfin configuration and uploaded media."
  default     = "azureuser"
  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{2,30}$", var.admin_username)) && !contains(["root", "admin"], var.admin_username)
    error_message = "Use a nonreserved Linux username with 3-31 lowercase letters, digits or underscores."
  }
}

variable "ssh_public_key" {
  type        = string
  description = "Single-line OpenSSH RSA (Azure requires >=2048 bits) or Ed25519 public key; never a private key."
  validation {
    condition     = can(regex("^(ssh-ed25519|ssh-rsa) [A-Za-z0-9+/]+={0,3}( [A-Za-z0-9@._-]+)?$", var.ssh_public_key))
    error_message = "Provide a single-line ssh-ed25519 or ssh-rsa public key with an optional simple comment."
  }
}

variable "administrator_cidr" {
  type        = string
  description = "Required trusted public IPv4 CIDR for SSH and, by default, Jellyfin HTTPS. Prefer your fixed public IP/32."
  validation {
    condition     = can(cidrnetmask(var.administrator_cidr)) && can(regex("^[0-9./]+$", var.administrator_cidr)) && try(tonumber(split("/", var.administrator_cidr)[1]) >= 8, false)
    error_message = "Use an IPv4 CIDR with prefix /8 or narrower; unrestricted SSH is not permitted."
  }
}

variable "domain_name" {
  type        = string
  description = "Required user-owned public DNS hostname. Create its A record pointing to public_ip before ACME can succeed; remove conflicting AAAA records."
  validation {
    condition     = length(var.domain_name) <= 253 && can(regex("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}$", var.domain_name))
    error_message = "Use a lowercase public DNS hostname, without scheme, port, wildcard or trailing dot."
  }
}

variable "https_allowed_cidrs" {
  type        = list(string)
  description = "Caddy application-access IPv4 allowlist. Null restricts access to administrator_cidr. Set [\"0.0.0.0/0\"] ONLY after securing the first-run wizard. Public TCP 443 remains necessary for ACME TLS-ALPN; disallowed application requests receive 403."
  default     = null
  validation {
    condition     = var.https_allowed_cidrs == null ? true : length(var.https_allowed_cidrs) > 0 && alltrue([for cidr in var.https_allowed_cidrs : can(cidrnetmask(cidr)) && can(regex("^[0-9./]+$", cidr))])
    error_message = "Provide null or a nonempty list of IPv4 CIDRs."
  }
}

variable "media_disk_size_gb" {
  type        = number
  description = "Persistent LUN 0 managed media disk size; may grow but cannot shrink."
  default     = 512
  validation {
    condition     = var.media_disk_size_gb >= 32 && var.media_disk_size_gb <= 32767 && floor(var.media_disk_size_gb) == var.media_disk_size_gb
    error_message = "Use an integer from 32 to 32767 GiB."
  }
}

variable "os_disk_size_gb" {
  type        = number
  description = "Managed OS disk containing /srv/jellyfin/config and persistent Caddy certificates."
  default     = 64
  validation {
    condition     = var.os_disk_size_gb >= 32 && var.os_disk_size_gb <= 4095 && floor(var.os_disk_size_gb) == var.os_disk_size_gb
    error_message = "Use an integer from 32 to 4095 GiB."
  }
}

variable "backup_retention_days" {
  type        = number
  description = "Daily VM backup retention, including OS disk and media LUN 0; UTC 03:00 schedule."
  default     = 30
  validation {
    condition     = var.backup_retention_days >= 7 && var.backup_retention_days <= 9999 && floor(var.backup_retention_days) == var.backup_retention_days
    error_message = "Use an integer from 7 to 9999 days."
  }
}

variable "monthly_budget_amount" {
  type        = number
  description = "Monthly alert budget in subscription billing currency. Alerts do not cap spending."
  default     = 100
  validation {
    condition     = var.monthly_budget_amount > 0
    error_message = "Budget amount must be positive."
  }
}

variable "budget_start_date" {
  type        = string
  description = "Stable explicit first of month (YYYY-MM-01T00:00:00Z). Choose the current month on first apply; do not derive this from timestamp()."
  validation {
    condition     = can(regex("^20[0-9]{2}-(0[1-9]|1[0-2])-01T00:00:00Z$", var.budget_start_date)) && can(formatdate("YYYY-MM-DD", var.budget_start_date))
    error_message = "Use a valid first-of-month UTC timestamp."
  }
}

variable "budget_contact_emails" {
  type        = list(string)
  description = "One to five email recipients for 80% and 100% actual-spend alerts."
  validation {
    condition     = length(var.budget_contact_emails) >= 1 && length(var.budget_contact_emails) <= 5 && alltrue([for email in var.budget_contact_emails : can(regex("^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$", email))])
    error_message = "Provide one to five valid email addresses."
  }
}
