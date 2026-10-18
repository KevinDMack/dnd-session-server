resource "azurerm_resource_group" "jellyfin" {
  name     = "${var.name_prefix}-vm-rg"
  location = var.location
}

resource "azurerm_virtual_network" "jellyfin" {
  name                = "${var.name_prefix}-vnet"
  location            = azurerm_resource_group.jellyfin.location
  resource_group_name = azurerm_resource_group.jellyfin.name
  address_space       = ["10.42.0.0/16"]
}

resource "azurerm_subnet" "jellyfin" {
  name                 = "jellyfin"
  resource_group_name  = azurerm_resource_group.jellyfin.name
  virtual_network_name = azurerm_virtual_network.jellyfin.name
  address_prefixes     = ["10.42.1.0/24"]
  service_endpoints    = ["Microsoft.Storage"]
}

resource "azurerm_public_ip" "jellyfin" {
  name                = "${var.name_prefix}-ip"
  location            = azurerm_resource_group.jellyfin.location
  resource_group_name = azurerm_resource_group.jellyfin.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_security_group" "jellyfin" {
  name                = "${var.name_prefix}-nsg"
  location            = azurerm_resource_group.jellyfin.location
  resource_group_name = azurerm_resource_group.jellyfin.name

  security_rule {
    name                       = "ssh-administrator"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.administrator_cidr
    destination_address_prefix = "*"
  }

  # ACME TLS-ALPN validators have no stable source CIDRs. Caddy, not the NSG,
  # restricts application requests while keeping certificate issuance possible.
  security_rule {
    name                       = "https-and-acme"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "deny-other-inbound"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_interface" "jellyfin" {
  name                = "${var.name_prefix}-nic"
  location            = azurerm_resource_group.jellyfin.location
  resource_group_name = azurerm_resource_group.jellyfin.name

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.jellyfin.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.jellyfin.id
  }
}

resource "azurerm_network_interface_security_group_association" "jellyfin" {
  network_interface_id      = azurerm_network_interface.jellyfin.id
  network_security_group_id = azurerm_network_security_group.jellyfin.id
}

resource "azurerm_linux_virtual_machine" "jellyfin" {
  name                            = "${var.name_prefix}-vm"
  resource_group_name             = azurerm_resource_group.jellyfin.name
  location                        = azurerm_resource_group.jellyfin.location
  size                            = var.vm_size
  admin_username                  = var.admin_username
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.jellyfin.id]
  custom_data                     = base64encode(local.cloud_init)
  provision_vm_agent              = true
  allow_extension_operations      = true

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.media.id]
  }

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  os_disk {
    name                 = "${var.name_prefix}-os"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = var.os_disk_size_gb
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  # custom_data changes replace a VM, including its configuration-bearing OS disk.
  lifecycle {
    prevent_destroy = true
  }

  depends_on = [
    azurerm_network_interface_security_group_association.jellyfin,
    azurerm_role_assignment.media,
    azurerm_storage_share.media,
  ]
}

# Retain pre-migration disks and attachments. Operators must snapshot/copy data
# and detach explicitly; changing this module must never delete the old media.
removed {
  from = azurerm_managed_disk.media
  lifecycle {
    destroy = false
  }
}

removed {
  from = azurerm_virtual_machine_data_disk_attachment.media
  lifecycle {
    destroy = false
  }
}

resource "azurerm_recovery_services_vault" "jellyfin" {
  name                = "${var.name_prefix}-backup"
  location            = azurerm_resource_group.jellyfin.location
  resource_group_name = azurerm_resource_group.jellyfin.name
  sku                 = "Standard"
  storage_mode_type   = "GeoRedundant"
  soft_delete_enabled = true

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_backup_policy_vm" "jellyfin" {
  name                = "${var.name_prefix}-daily"
  resource_group_name = azurerm_resource_group.jellyfin.name
  recovery_vault_name = azurerm_recovery_services_vault.jellyfin.name
  timezone            = "UTC"
  policy_type         = "V1"

  backup {
    frequency = "Daily"
    time      = "03:00"
  }
  retention_daily {
    count = var.backup_retention_days
  }
}

resource "azurerm_backup_protected_vm" "jellyfin" {
  resource_group_name = azurerm_resource_group.jellyfin.name
  recovery_vault_name = azurerm_recovery_services_vault.jellyfin.name
  source_vm_id        = azurerm_linux_virtual_machine.jellyfin.id
  backup_policy_id    = azurerm_backup_policy_vm.jellyfin.id
}

resource "azurerm_consumption_budget_resource_group" "jellyfin" {
  name              = "${var.name_prefix}-monthly"
  resource_group_id = azurerm_resource_group.jellyfin.id
  amount            = var.monthly_budget_amount
  time_grain        = "Monthly"

  time_period {
    start_date = var.budget_start_date
  }

  dynamic "notification" {
    for_each = toset([80, 100])
    content {
      enabled        = true
      threshold      = notification.value
      operator       = "GreaterThanOrEqualTo"
      threshold_type = "Actual"
      contact_emails = var.budget_contact_emails
    }
  }
}
