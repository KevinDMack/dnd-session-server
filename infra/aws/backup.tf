resource "aws_backup_vault" "jellyfin" {
  name          = "${var.name_prefix}-backup"
  force_destroy = false

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_iam_role" "backup" {
  name_prefix = "${var.name_prefix}-backup-"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "backup.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_backup_plan" "jellyfin" {
  name = "${var.name_prefix}-daily"
  rule {
    rule_name         = "daily-ec2-and-media"
    target_vault_name = aws_backup_vault.jellyfin.name
    schedule          = "cron(0 3 * * ? *)"
    start_window      = 60
    completion_window = 360
    lifecycle {
      delete_after = var.backup_retention_days
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_backup_selection" "jellyfin" {
  name         = "${var.name_prefix}-ec2-and-media"
  plan_id      = aws_backup_plan.jellyfin.id
  iam_role_arn = aws_iam_role.backup.arn
  resources = concat(
    [aws_instance.jellyfin.arn],
    var.media_storage_type == "ebs" ? [aws_ebs_volume.media[0].arn] : [aws_efs_file_system.media[0].arn]
  )
  depends_on = [aws_iam_role_policy_attachment.backup]

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_budgets_budget" "jellyfin" {
  name         = "${var.name_prefix}-monthly-account"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_amount)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = toset([80, 100])
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = var.budget_contact_emails
    }
  }
}
