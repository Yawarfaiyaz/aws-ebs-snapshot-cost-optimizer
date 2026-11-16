data "aws_caller_identity" "current" {}

# Who may use this role: only the Lambda service.
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${var.project_name}-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

# What the role may do: least privilege.
data "aws_iam_policy_document" "lambda_permissions" {
  # Describe calls cannot be limited to specific resources in AWS.
  statement {
    sid = "ReadEbs"
    actions = [
      "ec2:DescribeSnapshots",
      "ec2:DescribeVolumes",
      "ec2:DescribeImages",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "DeleteSnapshotsInThisRegion"
    actions   = ["ec2:DeleteSnapshot"]
    resources = ["arn:aws:ec2:${var.aws_region}::snapshot/*"]
  }

  statement {
    sid       = "PublishReport"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
  }

  statement {
    sid = "WriteOwnLogs"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.lambda.arn}:*"]
  }
}

resource "aws_iam_role_policy" "lambda" {
  name   = "${var.project_name}-lambda-policy"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda_permissions.json
}
