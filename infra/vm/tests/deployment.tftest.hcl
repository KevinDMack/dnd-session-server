# Run tests with Terraform >= 1.12 for plan-time mocks (deployment needs >= 1.9).
mock_provider "azurerm" {
  mock_resource "azurerm_user_assigned_identity" {
    override_during = plan
    defaults = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/jellyfin-vm-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/jellyfin-media"
      client_id    = "11111111-1111-1111-1111-111111111111"
      principal_id = "22222222-2222-2222-2222-222222222222"
    }
  }
}

mock_provider "azapi" {
  mock_resource "azapi_resource" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/jellyfin-vm-rg/providers/Microsoft.Storage/storageAccounts/jftest"
    }
  }
}

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
    condition     = azurerm_linux_virtual_machine.jellyfin.disable_password_authentication && azurerm_linux_virtual_machine.jellyfin.identity[0].type == "UserAssigned" && azurerm_role_assignment.media.role_definition_name == "Storage File Data SMB MI Admin"
    error_message = "VM must use key-only SSH and a dedicated identity with SMB OAuth data access."
  }
  assert {
    condition     = azurerm_storage_share.media.quota == 512 && azurerm_storage_share.media.access_tier == "Hot" && azurerm_storage_share.media.enabled_protocol == "SMB" && azapi_resource.media.body.properties.azureFilesIdentityBasedAuthentication.smbOAuthSettings.isSmbOAuthEnabled && azapi_resource.media.body.properties.azureFilesIdentityBasedAuthentication.directoryServiceOptions == "None"
    error_message = "Expected a 512 GiB Hot SMB share with genuine managed identity OAuth enabled."
  }
  assert {
    condition     = azurerm_recovery_services_vault.jellyfin.soft_delete_enabled && azurerm_backup_policy_vm.jellyfin.backup[0].frequency == "Daily" && azurerm_backup_policy_vm.jellyfin.retention_daily[0].count == 30 && azurerm_backup_policy_file_share.media.retention_daily[0].count == 30 && azurerm_backup_protected_file_share.media.source_file_share_name == azurerm_storage_share.media.name
    error_message = "Daily backups must protect OS/config and separately the SMB share for 30 days."
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
    condition     = length(yamldecode(local.cloud_init).write_files) == 8 && alltrue([for entry in yamldecode(local.cloud_init).write_files : entry.encoding == "b64" && can(base64decode(entry.content))])
    error_message = "Cloud-init must render valid YAML with base64-encoded file contents."
  }
  assert {
    condition     = strcontains(base64decode(one([for entry in yamldecode(local.cloud_init).write_files : entry.content if entry.path == "/etc/caddy/Caddyfile"])), "@allowed remote_ip 203.0.113.10/32") && strcontains(base64decode(one([for entry in yamldecode(local.cloud_init).write_files : entry.content if entry.path == "/etc/caddy/Caddyfile"])), "disable_http_challenge")
    error_message = "Caddy must enforce the allowlist and use TLS-ALPN, not HTTP ACME."
  }
  assert {
    condition     = azapi_resource.media.body.properties.networkAcls.defaultAction == "Deny" && azapi_resource.media.body.properties.networkAcls.bypass == "AzureServices" && length(azapi_resource.media.body.properties.networkAcls.virtualNetworkRules) == 1 && length(azapi_resource.media.body.properties.networkAcls.ipRules) == 0 && contains(azurerm_subnet.jellyfin.service_endpoints, "Microsoft.Storage")
    error_message = "The share must allow only the VM subnet and trusted backup services."
  }
  assert {
    condition     = azapi_resource.media.body.properties.allowSharedKeyAccess && length(azapi_resource.media.response_export_values) == 0
    error_message = "Azure Backup requires Shared Key enabled, but account responses must not export keys into state."
  }
  assert {
    condition     = strcontains(file("${path.module}/media.mount.tftpl"), "ro,username=") && strcontains(file("${path.module}/media.mount.tftpl"), "sec=krb5,cruid=azfilesuser") && strcontains(file("${path.module}/media.mount.tftpl"), "vers=3.1.1,seal") && strcontains(file("${path.module}/media-auth.sh"), "--imds-client-id") && strcontains(file("${path.module}/media-auth.sh"), "attempt <= 60") && strcontains(file("${path.module}/media-auth.sh"), "mount -t cifs")
    error_message = "Media must use encrypted read-only SMB, package-owned credentials, and retried IMDS OAuth bootstrap."
  }
  assert {
    condition     = strcontains(file("${path.module}/install-azfilesauth.sh"), "enable --now azfilesrefresh.service") && strcontains(file("${path.module}/media.mount.tftpl"), "Requires=jellyfin-media-auth.service") && strcontains(file("${path.module}/container.service.tftpl"), "BindsTo=srv-jellyfin-media.mount") && !strcontains(file("${path.module}/container.service.tftpl"), "chown 1000:1000 /srv/jellyfin/media")
    error_message = "Reboot authentication, renewal and fail-closed mount ordering are required; never chown the SMB root."
  }
  assert {
    condition     = alltrue([for entry in yamldecode(local.cloud_init).write_files : !strcontains(lower(base64decode(entry.content)), "listkeys") && !strcontains(base64decode(entry.content), "credentials=") && !strcontains(base64decode(entry.content), "password=")])
    error_message = "Cloud-init and authentication must not fetch or embed storage account credentials."
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

run "reject_fractional_share_quota" {
  command = plan
  variables {
    media_share_quota_gb = 512.5
  }
  expect_failures = [var.media_share_quota_gb]
}

run "reject_excessive_share_backup_retention" {
  command = plan
  variables {
    backup_retention_days = 201
  }
  expect_failures = [var.backup_retention_days]
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
