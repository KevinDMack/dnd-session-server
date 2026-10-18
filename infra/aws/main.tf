data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_partition" "current" {}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

locals {
  availability_zone = coalesce(var.availability_zone, data.aws_availability_zones.available.names[0])
}

resource "aws_vpc" "jellyfin" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.name_prefix}-vpc" }
}

resource "aws_subnet" "jellyfin" {
  vpc_id                  = aws_vpc.jellyfin.id
  cidr_block              = "10.42.1.0/24"
  availability_zone       = local.availability_zone
  map_public_ip_on_launch = false
  tags                    = { Name = "${var.name_prefix}-public" }
}

resource "aws_internet_gateway" "jellyfin" {
  vpc_id = aws_vpc.jellyfin.id
}

resource "aws_route_table" "jellyfin" {
  vpc_id = aws_vpc.jellyfin.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.jellyfin.id
  }
}

resource "aws_route_table_association" "jellyfin" {
  subnet_id      = aws_subnet.jellyfin.id
  route_table_id = aws_route_table.jellyfin.id
}

resource "aws_security_group" "jellyfin" {
  name_prefix = "${var.name_prefix}-instance-"
  description = "Administrator SSH and public TLS-ALPN; application allowlist is enforced by Caddy"
  vpc_id      = aws_vpc.jellyfin.id
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  security_group_id = aws_security_group.jellyfin.id
  description       = "SSH from the administrator only"
  cidr_ipv4         = var.administrator_cidr
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  security_group_id = aws_security_group.jellyfin.id
  description       = "TLS-ALPN ACME and Caddy HTTPS; never expose Jellyfin 8096"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "jellyfin" {
  security_group_id = aws_security_group.jellyfin.id
  description       = "Package/image downloads, DNS, ACME and media access"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_key_pair" "administrator" {
  key_name_prefix = "${var.name_prefix}-"
  public_key      = var.ssh_public_key
}

resource "aws_iam_role" "jellyfin" {
  name_prefix = "${var.name_prefix}-instance-"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_instance_profile" "jellyfin" {
  name_prefix = "${var.name_prefix}-"
  role        = aws_iam_role.jellyfin.name
}

resource "aws_network_interface" "jellyfin" {
  subnet_id       = aws_subnet.jellyfin.id
  security_groups = [aws_security_group.jellyfin.id]
  tags            = { Name = var.name_prefix }
}

resource "aws_instance" "jellyfin" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.medium"
  availability_zone           = local.availability_zone
  key_name                    = aws_key_pair.administrator.key_name
  iam_instance_profile        = aws_iam_instance_profile.jellyfin.name
  disable_api_termination     = true
  user_data                   = local.cloud_init
  user_data_replace_on_change = true

  primary_network_interface {
    network_interface_id = aws_network_interface.jellyfin.id
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  credit_specification {
    cpu_credits = "standard"
  }

  root_block_device {
    encrypted             = true
    volume_type           = "gp3"
    volume_size           = var.os_disk_size_gb
    delete_on_termination = false
    tags                  = { Name = "${var.name_prefix}-root-config" }
  }

  tags = { Name = var.name_prefix }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [ami]
  }

  # EBS attachment necessarily follows instance creation; bootstrap retries it.
  depends_on = [
    aws_route_table_association.jellyfin,
    aws_eip_association.jellyfin,
    aws_vpc_security_group_egress_rule.jellyfin,
    aws_efs_mount_target.media,
    aws_efs_file_system_policy.media,
    aws_iam_role_policy.media
  ]
}

resource "aws_eip" "jellyfin" {
  domain     = "vpc"
  tags       = { Name = var.name_prefix }
  depends_on = [aws_internet_gateway.jellyfin]
}

resource "aws_eip_association" "jellyfin" {
  allocation_id        = aws_eip.jellyfin.id
  network_interface_id = aws_network_interface.jellyfin.id
}
