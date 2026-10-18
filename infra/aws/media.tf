resource "aws_ebs_volume" "media" {
  count             = var.media_storage_type == "ebs" ? 1 : 0
  availability_zone = local.availability_zone
  encrypted         = true
  type              = "gp3"
  size              = var.media_volume_size_gb
  tags              = { Name = "${var.name_prefix}-media" }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_volume_attachment" "media" {
  count        = var.media_storage_type == "ebs" ? 1 : 0
  device_name  = "/dev/sdf"
  volume_id    = aws_ebs_volume.media[0].id
  instance_id  = aws_instance.jellyfin.id
  force_detach = false
}

resource "aws_efs_file_system" "media" {
  count                  = var.media_storage_type == "efs" ? 1 : 0
  creation_token         = "${var.name_prefix}-media"
  encrypted              = true
  availability_zone_name = var.efs_one_zone ? local.availability_zone : null
  performance_mode       = "generalPurpose"
  throughput_mode        = "bursting"
  tags                   = { Name = "${var.name_prefix}-media" }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_efs_access_point" "media" {
  count          = var.media_storage_type == "efs" ? 1 : 0
  file_system_id = aws_efs_file_system.media[0].id
  posix_user {
    uid = 1000
    gid = 1000
  }
  root_directory {
    path = "/media"
    creation_info {
      owner_uid   = 1000
      owner_gid   = 1000
      permissions = "0755"
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_security_group" "media" {
  count       = var.media_storage_type == "efs" ? 1 : 0
  name_prefix = "${var.name_prefix}-efs-"
  description = "EFS NFS from the Jellyfin instance security group only"
  vpc_id      = aws_vpc.jellyfin.id
}

resource "aws_vpc_security_group_ingress_rule" "nfs" {
  count                        = var.media_storage_type == "efs" ? 1 : 0
  security_group_id            = aws_security_group.media[0].id
  referenced_security_group_id = aws_security_group.jellyfin.id
  ip_protocol                  = "tcp"
  from_port                    = 2049
  to_port                      = 2049
}

resource "aws_efs_mount_target" "media" {
  count           = var.media_storage_type == "efs" ? 1 : 0
  file_system_id  = aws_efs_file_system.media[0].id
  subnet_id       = aws_subnet.jellyfin.id
  security_groups = [aws_security_group.media[0].id]
  depends_on      = [aws_vpc_security_group_ingress_rule.nfs]
}

resource "aws_iam_role_policy" "media" {
  count = var.media_storage_type == "efs" ? 1 : 0
  name  = "media-access-point"
  role  = aws_iam_role.jellyfin.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["elasticfilesystem:ClientMount"]
      Resource = aws_efs_file_system.media[0].arn
      Condition = {
        Bool         = { "aws:SecureTransport" = "true" }
        StringEquals = { "elasticfilesystem:AccessPointArn" = aws_efs_access_point.media[0].arn }
      }
    }]
  })
}

resource "aws_efs_file_system_policy" "media" {
  count          = var.media_storage_type == "efs" ? 1 : 0
  file_system_id = aws_efs_file_system.media[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowInstanceAccessPoint"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.jellyfin.arn }
        Action    = ["elasticfilesystem:ClientMount"]
        Resource  = aws_efs_file_system.media[0].arn
        Condition = {
          Bool         = { "aws:SecureTransport" = "true" }
          StringEquals = { "elasticfilesystem:AccessPointArn" = aws_efs_access_point.media[0].arn }
        }
      },
      {
        Sid       = "DenyUnencryptedTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "elasticfilesystem:Client*"
        Resource  = aws_efs_file_system.media[0].arn
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        Sid       = "DenyOtherPrincipals"
        Effect    = "Deny"
        Principal = "*"
        Action    = "elasticfilesystem:Client*"
        Resource  = aws_efs_file_system.media[0].arn
        Condition = { ArnNotEquals = { "aws:PrincipalArn" = aws_iam_role.jellyfin.arn } }
      },
      {
        Sid       = "DenyOtherAccessPoints"
        Effect    = "Deny"
        Principal = "*"
        Action    = "elasticfilesystem:Client*"
        Resource  = aws_efs_file_system.media[0].arn
        Condition = { ArnNotEquals = { "elasticfilesystem:AccessPointArn" = aws_efs_access_point.media[0].arn } }
      }
    ]
  })
}
