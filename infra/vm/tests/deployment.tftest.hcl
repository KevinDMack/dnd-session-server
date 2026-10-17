mock_provider "azurerm" {}

variables {
  subscription_id       = "00000000-0000-0000-0000-000000000000"
  administrator_cidr    = "203.0.113.10/32"
  domain_name           = "media.example.com"
  ssh_public_key        = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4f"
  budget_contact_emails = ["admin@example.com"]
  budget_start_date     = "2026-10-01T00:00:00Z"
}

run "production_defaults" {
  command = plan

  assert {
    condition     = azurerm_linux_virtual_machine.jellyfin.size == "Standard_B2s" && azurerm_resource_group.jellyfin.location == "eastus"
    error_message = "Expected the economical East US VM defaults."
  }
  assert {
    condition     = azurerm_linux_virtual_machine.jellyfin.disable_password_authentication && length(azurerm_linux_virtual_machine.jellyfin.identity) == 0
    error_message = "VM must use key-only SSH without an unnecessary managed identity."
  }
  assert {
    condition     = azurerm_managed_disk.media.disk_size_gb == 512 && azurerm_virtual_machine_data_disk_attachment.media.lun == 0
    error_message = "Expected a persistent 512 GiB media disk at LUN 0."
  }
  assert {
    condition     = azurerm_recovery_services_vault.jellyfin.soft_delete_enabled && azurerm_backup_policy_vm.jellyfin.backup[0].frequency == "Daily" && azurerm_backup_policy_vm.jellyfin.retention_daily[0].count == 30 && azurerm_backup_protected_vm.jellyfin.include_disk_luns == toset([0])
    error_message = "Daily backups must retain 30 days and include the media disk."
  }
  assert {
    condition     = local.https_cidrs == tolist(["203.0.113.10/32"])
    error_message = "The first-run application allowlist must default to the administrator CIDR."
  }
  assert {
    condition     = length(azurerm_network_security_group.jellyfin.security_rule) == 3 && alltrue([for rule in azurerm_network_security_group.jellyfin.security_rule : rule.access != "Allow" || contains(["22", "443"], rule.destination_port_range)])
    error_message = "Only SSH and TLS should be permitted inbound; never port 8096 or 80."
  }
  assert {
    condition     = one([for rule in azurerm_network_security_group.jellyfin.security_rule : rule.source_address_prefix if rule.name == "ssh-administrator"]) == var.administrator_cidr
    error_message = "SSH must be restricted to the required administrator CIDR."
  }
  assert {
    condition     = azurerm_consumption_budget_resource_group.jellyfin.time_period[0].start_date == var.budget_start_date && length(azurerm_consumption_budget_resource_group.jellyfin.notification) == 2
    error_message = "Use a stable budget start date and both spend alerts."
  }
  assert {
    condition     = strcontains(local.services.jellyfin.args, "127.0.0.1:8096:8096") && strcontains(local.services.jellyfin.args, "dst=/media,readonly")
    error_message = "Jellyfin must bind only to loopback and have read-only media."
  }
  assert {
    condition     = length(yamldecode(local.cloud_init).write_files) == 7 && alltrue([for entry in yamldecode(local.cloud_init).write_files : entry.encoding == "b64" && can(base64decode(entry.content))])
    error_message = "Cloud-init must render valid YAML with base64-encoded file contents."
  }
  assert {
    condition     = strcontains(base64decode(one([for entry in yamldecode(local.cloud_init).write_files : entry.content if entry.path == "/etc/caddy/Caddyfile"])), "@allowed remote_ip 203.0.113.10/32") && strcontains(base64decode(one([for entry in yamldecode(local.cloud_init).write_files : entry.content if entry.path == "/etc/caddy/Caddyfile"])), "disable_http_challenge")
    error_message = "Caddy must enforce the allowlist and use TLS-ALPN, not HTTP ACME."
  }
}

run "explicit_https_allowlist" {
  command = plan
  variables {
    https_allowed_cidrs = ["0.0.0.0/0"]
  }
  assert {
    condition     = local.https_cidrs == tolist(["0.0.0.0/0"])
    error_message = "An explicit application allowlist must override the administrator-only default."
  }
}

run "reject_domain_injection" {
  command = plan
  variables {
    domain_name = "media.example.com\nrespond injected"
  }
  expect_failures = [var.domain_name]
}

run "reject_cidr_injection" {
  command = plan
  variables {
    https_allowed_cidrs = ["203.0.113.10/32\nhandle {"]
  }
  expect_failures = [var.https_allowed_cidrs]
}

run "reject_unrestricted_ssh" {
  command = plan
  variables {
    administrator_cidr = "0.0.0.0/0"
  }
  expect_failures = [var.administrator_cidr]
}

run "reject_empty_https_allowlist" {
  command = plan
  variables {
    https_allowed_cidrs = []
  }
  expect_failures = [var.https_allowed_cidrs]
}

run "reject_fractional_disk" {
  command = plan
  variables {
    media_disk_size_gb = 512.5
  }
  expect_failures = [var.media_disk_size_gb]
}

run "reject_unstable_budget_date" {
  command = plan
  variables {
    budget_start_date = "2026-10-17T00:00:00Z"
  }
  expect_failures = [var.budget_start_date]
}

run "reject_missing_budget_recipients" {
  command = plan
  variables {
    budget_contact_emails = []
  }
  expect_failures = [var.budget_contact_emails]
}
