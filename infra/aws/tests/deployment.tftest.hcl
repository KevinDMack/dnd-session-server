# Terraform >= 1.12 is needed for plan-time mocks; deployment supports >= 1.9.
mock_provider "aws" {
  override_during = plan
  mock_data "aws_availability_zones" {
    defaults = { names = ["us-east-1a", "us-east-1b"] }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_ami" {
    defaults = { id = "ami-0123456789abcdef0" }
  }
  mock_resource "aws_iam_role" {
    override_during = plan
    defaults = {
      arn  = "arn:aws:iam::123456789012:role/jellyfin"
      name = "jellyfin"
    }
  }
  mock_resource "aws_iam_instance_profile" {
    defaults = { name = "jellyfin-profile" }
  }
  mock_resource "aws_network_interface" {
    defaults = { id = "eni-0123456789abcdef0" }
  }
  mock_resource "aws_security_group" {
    defaults = { id = "sg-0123456789abcdef0" }
  }
  mock_resource "aws_subnet" {
    defaults = { id = "subnet-0123456789abcdef0" }
  }
  mock_resource "aws_instance" {
    override_during = plan
    defaults = {
      id  = "i-0123456789abcdef0"
      arn = "arn:aws:ec2:us-east-1:123456789012:instance/i-0123456789abcdef0"
    }
  }
  mock_resource "aws_ebs_volume" {
    override_during = plan
    defaults = {
      id  = "vol-0123456789abcdef0"
      arn = "arn:aws:ec2:us-east-1:123456789012:volume/vol-0123456789abcdef0"
    }
  }
  mock_resource "aws_efs_file_system" {
    override_during = plan
    defaults = {
      id                     = "fs-0123456789abcdef0"
      arn                    = "arn:aws:elasticfilesystem:us-east-1:123456789012:file-system/fs-0123456789abcdef0"
      availability_zone_name = ""
      dns_name               = "fs-0123456789abcdef0.efs.us-east-1.amazonaws.com"
    }
  }
  mock_resource "aws_efs_access_point" {
    override_during = plan
    defaults = {
      id  = "fsap-0123456789abcdef0"
      arn = "arn:aws:elasticfilesystem:us-east-1:123456789012:access-point/fsap-0123456789abcdef0"
    }
  }
}

variables {
  administrator_cidr    = "203.0.113.10/32"
  domain_name           = "media.example.com"
  ssh_public_key        = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4f"
  budget_contact_emails = ["admin@example.com"]
}

run "ebs_defaults" {
  command = plan

  assert {
    condition     = var.region == "us-east-1" && aws_instance.jellyfin.instance_type == "t3.medium" && aws_instance.jellyfin.credit_specification[0].cpu_credits == "standard"
    error_message = "Use the economical us-east-1 t3.medium defaults without unlimited CPU credit charges."
  }
  assert {
    condition     = length(data.aws_ami.ubuntu.owners) == 1 && contains(data.aws_ami.ubuntu.owners, "099720109477") && data.aws_ami.ubuntu.most_recent && contains(one([for f in data.aws_ami.ubuntu.filter : f.values if f.name == "name"]), "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*")
    error_message = "Resolve only Canonical's Ubuntu 24.04 amd64 AMI."
  }
  assert {
    condition     = aws_instance.jellyfin.root_block_device[0].encrypted && aws_instance.jellyfin.root_block_device[0].volume_type == "gp3" && aws_instance.jellyfin.root_block_device[0].volume_size == 64 && !aws_instance.jellyfin.root_block_device[0].delete_on_termination
    error_message = "The 64 GiB gp3 root/config disk must be encrypted and retained."
  }
  assert {
    condition     = aws_instance.jellyfin.metadata_options[0].http_tokens == "required" && aws_instance.jellyfin.metadata_options[0].http_put_response_hop_limit == 1 && aws_instance.jellyfin.disable_api_termination && aws_instance.jellyfin.user_data_replace_on_change
    error_message = "Require IMDSv2, hop limit 1, termination protection and explicit user-data replacement."
  }
  assert {
    condition     = aws_instance.jellyfin.iam_instance_profile == aws_iam_instance_profile.jellyfin.name && jsondecode(aws_iam_role.jellyfin.assume_role_policy).Statement[0].Principal.Service == "ec2.amazonaws.com"
    error_message = "The VM requires a dedicated EC2 instance profile."
  }
  assert {
    condition     = length(aws_ebs_volume.media) == 1 && length(aws_efs_file_system.media) == 0 && aws_ebs_volume.media[0].encrypted && aws_ebs_volume.media[0].type == "gp3" && aws_ebs_volume.media[0].size == 512 && aws_ebs_volume.media[0].availability_zone == aws_instance.jellyfin.availability_zone && aws_volume_attachment.media[0].device_name == "/dev/sdf" && !aws_volume_attachment.media[0].force_detach
    error_message = "Default media must be an independent encrypted 512 GiB gp3 disk attached in the same AZ."
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.ssh.cidr_ipv4 == var.administrator_cidr && aws_vpc_security_group_ingress_rule.ssh.from_port == 22 && aws_vpc_security_group_ingress_rule.https.from_port == 443 && aws_vpc_security_group_ingress_rule.https.to_port == 443 && aws_vpc_security_group_ingress_rule.https.cidr_ipv4 == "0.0.0.0/0" && length(aws_vpc_security_group_ingress_rule.nfs) == 0 && local.https_cidrs == tolist([var.administrator_cidr])
    error_message = "Only administrator SSH and public TLS-ALPN are exposed; application access defaults to the administrator."
  }
  assert {
    condition     = aws_eip.jellyfin.domain == "vpc" && aws_eip_association.jellyfin.network_interface_id == aws_network_interface.jellyfin.id && aws_instance.jellyfin.primary_network_interface[0].network_interface_id == aws_network_interface.jellyfin.id && !aws_subnet.jellyfin.map_public_ip_on_launch && aws_network_interface.jellyfin.security_groups == toset([aws_security_group.jellyfin.id]) && aws_vpc.jellyfin.enable_dns_support && aws_vpc.jellyfin.enable_dns_hostnames && strcontains(file("${path.module}/main.tf"), "aws_route_table_association.jellyfin,") && strcontains(file("${path.module}/main.tf"), "aws_eip_association.jellyfin,")
    error_message = "Bind the primary ENI's EIP and ready the subnet route before boot, without ephemeral public IPs or interrupted apt connectivity."
  }
  assert {
    condition     = one(aws_backup_plan.jellyfin.rule).schedule == "cron(0 3 * * ? *)" && one(one(aws_backup_plan.jellyfin.rule).lifecycle).delete_after == 30 && toset(aws_backup_selection.jellyfin.resources) == toset([aws_instance.jellyfin.arn, aws_ebs_volume.media[0].arn]) && !aws_backup_vault.jellyfin.force_destroy
    error_message = "Daily 30-day backups must select both EC2/config and the separate EBS media volume."
  }
  assert {
    condition     = endswith(aws_iam_role_policy_attachment.backup.policy_arn, "service-role/AWSBackupServiceRolePolicyForBackup") && jsondecode(aws_iam_role.backup.assume_role_policy).Statement[0].Principal.Service == "backup.amazonaws.com"
    error_message = "AWS Backup needs its own service role with the managed backup policy."
  }
  assert {
    condition     = aws_budgets_budget.jellyfin.limit_amount == "100" && aws_budgets_budget.jellyfin.limit_unit == "USD" && aws_budgets_budget.jellyfin.time_unit == "MONTHLY" && toset([for n in aws_budgets_budget.jellyfin.notification : n.threshold]) == toset([80, 100]) && alltrue([for n in aws_budgets_budget.jellyfin.notification : n.notification_type == "ACTUAL" && n.threshold_type == "PERCENTAGE" && n.subscriber_email_addresses == toset(var.budget_contact_emails)])
    error_message = "Email 80% and 100% actual-spend monthly USD budget alerts."
  }
  assert {
    condition     = strcontains(file("${path.module}/main.tf"), "prevent_destroy = true") && strcontains(file("${path.module}/main.tf"), "ignore_changes  = [ami]") && length(regexall("prevent_destroy = true", file("${path.module}/media.tf"))) == 3 && length(regexall("prevent_destroy = true", file("${path.module}/backup.tf"))) == 3
    error_message = "VM, both media backends/access point and backup vault/plan/selection need destruction guards; ignore incidental AMI refreshes."
  }
  assert {
    condition     = length(base64encode(local.cloud_init)) / 4 * 3 - length(regexall("=", base64encode(local.cloud_init))) <= 16384 && length(yamldecode(local.cloud_init).write_files) == 7 && alltrue([for entry in yamldecode(local.cloud_init).write_files : entry.encoding == "b64" && can(base64decode(entry.content))]) && yamldecode(local.cloud_init).package_update && !yamldecode(local.cloud_init).ssh_pwauth && yamldecode(local.cloud_init).disable_root
    error_message = "Render valid, key-only cloud-init with base64 file payloads within EC2's 16 KiB user-data limit."
  }
  assert {
    condition     = strcontains(base64decode(one([for entry in yamldecode(local.cloud_init).write_files : entry.content if entry.path == "/etc/systemd/system/srv-jellyfin-media.mount"])), "What=/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_vol0123456789abcdef0") && strcontains(base64decode(one([for entry in yamldecode(local.cloud_init).write_files : entry.content if entry.path == "/etc/systemd/system/jellyfin-prepare-media.service"])), "ebs vol-0123456789abcdef0 none")
    error_message = "EBS bootstrap must select the independently attached disk by its stable volume ID, not enumeration."
  }
  assert {
    condition     = strcontains(base64decode(one([for entry in yamldecode(local.cloud_init).write_files : entry.content if entry.path == "/etc/systemd/system/srv-jellyfin-media.mount"])), "Type=ext4") && strcontains(base64decode(one([for entry in yamldecode(local.cloud_init).write_files : entry.content if entry.path == "/etc/systemd/system/srv-jellyfin-media.mount"])), "Options=defaults,nodev,nosuid,noexec")
    error_message = "EBS must render an ext4 mount with hardened options, not an EFS mount."
  }
  assert {
    condition     = strcontains(file("${path.module}/prepare-media.sh"), "attempt <= 120") && strcontains(file("${path.module}/prepare-media.sh"), "lsblk --nodeps --noheadings --paths --output NAME,SERIAL") && strcontains(file("${path.module}/prepare-media.sh"), "$2 == serial") && strcontains(file("${path.module}/prepare-media.sh"), "wipefs --no-act") && strcontains(file("${path.module}/prepare-media.sh"), "refusing initialization") && strcontains(file("${path.module}/prepare-media.sh"), "refusing to modify existing data") && strcontains(file("${path.module}/prepare-media.sh"), "udevadm settle")
    error_message = "EBS preparation must wait for attachment and refuse to format disks with existing/unknown signatures."
  }
  assert {
    condition     = strcontains(local.services.jellyfin.args, "--user 1000:1000") && strcontains(local.services.jellyfin.args, "127.0.0.1:8096:8096") && strcontains(local.services.jellyfin.args, "dst=/media,readonly") && can(regex("@sha256:[0-9a-f]{64}$", local.jellyfin_image)) && can(regex("@sha256:[0-9a-f]{64}$", local.caddy_image)) && strcontains(file("${path.module}/../vm/container.service.tftpl"), "BindsTo=srv-jellyfin-media.mount")
    error_message = "Digest-pinned containers must run Jellyfin as UID 1000 on loopback with read-only media and fail-closed mount ordering."
  }
  assert {
    condition     = strcontains(base64decode(one([for entry in yamldecode(local.cloud_init).write_files : entry.content if entry.path == "/etc/caddy/Caddyfile"])), "@allowed remote_ip 203.0.113.10/32") && strcontains(base64decode(one([for entry in yamldecode(local.cloud_init).write_files : entry.content if entry.path == "/etc/caddy/Caddyfile"])), "disable_http_challenge")
    error_message = "Caddy must enforce the administrator-only initial allowlist and TLS-ALPN ACME."
  }
}

run "regional_efs" {
  command = plan
  variables {
    media_storage_type = "efs"
  }
  assert {
    condition     = length(aws_ebs_volume.media) == 0 && length(aws_volume_attachment.media) == 0 && length(aws_efs_file_system.media) == 1 && aws_efs_file_system.media[0].encrypted && aws_efs_file_system.media[0].availability_zone_name == ""
    error_message = "The EFS alternative must be encrypted regional storage by default and have no EBS media."
  }
  assert {
    condition     = aws_efs_access_point.media[0].posix_user[0].uid == 1000 && aws_efs_access_point.media[0].posix_user[0].gid == 1000 && aws_efs_access_point.media[0].root_directory[0].path == "/media" && aws_efs_access_point.media[0].root_directory[0].creation_info[0].owner_uid == 1000 && aws_efs_access_point.media[0].root_directory[0].creation_info[0].owner_gid == 1000 && aws_efs_access_point.media[0].root_directory[0].creation_info[0].permissions == "0755"
    error_message = "EFS must use a /media access point owned by UID/GID 1000 with 0755 permissions."
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.nfs[0].referenced_security_group_id == aws_security_group.jellyfin.id && aws_vpc_security_group_ingress_rule.nfs[0].from_port == 2049 && aws_vpc_security_group_ingress_rule.nfs[0].to_port == 2049 && aws_vpc_security_group_ingress_rule.nfs[0].cidr_ipv4 == null && aws_efs_mount_target.media[0].subnet_id == aws_subnet.jellyfin.id
    error_message = "Only the instance security group may reach NFS in its subnet."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.media[0].policy).Statement[0].Resource == aws_efs_file_system.media[0].arn && jsondecode(aws_iam_role_policy.media[0].policy).Statement[0].Condition.Bool["aws:SecureTransport"] == "true" && jsondecode(aws_iam_role_policy.media[0].policy).Statement[0].Condition.StringEquals["elasticfilesystem:AccessPointArn"] == aws_efs_access_point.media[0].arn
    error_message = "The instance's read-only EFS permission must require TLS and the selected access point."
  }
  assert {
    condition     = jsondecode(aws_efs_file_system_policy.media[0].policy).Statement[0].Principal.AWS == aws_iam_role.jellyfin.arn && jsondecode(aws_efs_file_system_policy.media[0].policy).Statement[1].Effect == "Deny" && jsondecode(aws_efs_file_system_policy.media[0].policy).Statement[1].Condition.Bool["aws:SecureTransport"] == "false" && jsondecode(aws_efs_file_system_policy.media[0].policy).Statement[2].Condition.ArnNotEquals["aws:PrincipalArn"] == aws_iam_role.jellyfin.arn && jsondecode(aws_efs_file_system_policy.media[0].policy).Statement[3].Condition.ArnNotEquals["elasticfilesystem:AccessPointArn"] == aws_efs_access_point.media[0].arn
    error_message = "EFS must explicitly reject plaintext, other IAM principals and missing/wrong access points."
  }
  assert {
    condition     = toset(aws_backup_selection.jellyfin.resources) == toset([aws_instance.jellyfin.arn, aws_efs_file_system.media[0].arn])
    error_message = "EFS backups must explicitly protect EC2/config and the filesystem."
  }
  assert {
    condition     = length(base64encode(local.cloud_init)) / 4 * 3 - length(regexall("=", base64encode(local.cloud_init))) <= 16384 && strcontains(base64decode(one([for entry in yamldecode(local.cloud_init).write_files : entry.content if entry.path == "/etc/systemd/system/srv-jellyfin-media.mount"])), "Options=_netdev,ro,tls,iam,accesspoint=fsap-0123456789abcdef0") && strcontains(base64decode(one([for entry in yamldecode(local.cloud_init).write_files : entry.content if entry.path == "/etc/systemd/system/jellyfin-prepare-media.service"])), "efs none fs-0123456789abcdef0.efs.us-east-1.amazonaws.com")
    error_message = "EFS cloud-init must render TLS/IAM/access-point read-only mounts and wait for mount-target DNS."
  }
  assert {
    condition     = length(yamldecode(local.cloud_init).write_files) == 7 && alltrue([for entry in yamldecode(local.cloud_init).write_files : entry.encoding == "b64" && can(base64decode(entry.content))]) && strcontains(base64decode(one([for entry in yamldecode(local.cloud_init).write_files : entry.content if entry.path == "/etc/systemd/system/srv-jellyfin-media.mount"])), "What=fs-0123456789abcdef0:/") && strcontains(base64decode(one([for entry in yamldecode(local.cloud_init).write_files : entry.content if entry.path == "/etc/systemd/system/srv-jellyfin-media.mount"])), "Type=efs")
    error_message = "EFS cloud-init must decode all base64 file payloads and select the EFS source and mount helper."
  }
  assert {
    condition     = length(jsondecode(aws_iam_role_policy.media[0].policy).Statement[0].Action) == 1 && contains(jsondecode(aws_iam_role_policy.media[0].policy).Statement[0].Action, "elasticfilesystem:ClientMount") && length(jsondecode(aws_efs_file_system_policy.media[0].policy).Statement[0].Action) == 1 && contains(jsondecode(aws_efs_file_system_policy.media[0].policy).Statement[0].Action, "elasticfilesystem:ClientMount")
    error_message = "The host profile and filesystem grant must allow ClientMount only, never ClientWrite or ClientRootAccess."
  }
  assert {
    condition     = strcontains(file("${path.module}/prepare-media.sh"), "if ! command -v mount.efs") && strcontains(file("${path.module}/prepare-media.sh"), "https://amazon-efs-utils.aws.com/efs-utils-installer.sh") && strcontains(file("${path.module}/prepare-media.sh"), "getent ahostsv4")
    error_message = "Install the official EFS helper only if absent, wait for DNS and never fall back to unencrypted NFS."
  }
}

run "one_zone_efs" {
  command = plan
  variables {
    media_storage_type = "efs"
    efs_one_zone       = true
    availability_zone  = "us-east-1b"
  }
  assert {
    condition     = aws_efs_file_system.media[0].availability_zone_name == "us-east-1b" && aws_instance.jellyfin.availability_zone == "us-east-1b" && aws_subnet.jellyfin.availability_zone == "us-east-1b"
    error_message = "Opt-in One Zone EFS must use the same AZ as the VM and mount target subnet."
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

run "reject_unrestricted_ssh" {
  command = plan
  variables {
    administrator_cidr = "0.0.0.0/0"
  }
  expect_failures = [var.administrator_cidr]
}

run "reject_invalid_backend" {
  command = plan
  variables {
    media_storage_type = "s3"
  }
  expect_failures = [var.media_storage_type]
}

run "reject_empty_https_allowlist" {
  command = plan
  variables {
    https_allowed_cidrs = []
  }
  expect_failures = [var.https_allowed_cidrs]
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

run "reject_fractional_media_size" {
  command = plan
  variables {
    media_volume_size_gb = 512.5
  }
  expect_failures = [var.media_volume_size_gb]
}

run "reject_small_root" {
  command = plan
  variables {
    os_disk_size_gb = 32
  }
  expect_failures = [var.os_disk_size_gb]
}

run "reject_short_backup_retention" {
  command = plan
  variables {
    backup_retention_days = 1
  }
  expect_failures = [var.backup_retention_days]
}

run "reject_missing_budget_recipients" {
  command = plan
  variables {
    budget_contact_emails = []
  }
  expect_failures = [var.budget_contact_emails]
}

run "reject_nonpositive_budget" {
  command = plan
  variables {
    monthly_budget_amount = 0
  }
  expect_failures = [var.monthly_budget_amount]
}
