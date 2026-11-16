# Terraform zips the Python file itself, so no lambda.zip is committed to Git.
data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/../lambda/lambda_function.py"
  output_path = "${path.module}/build/lambda.zip"
}

resource "aws_lambda_function" "cleanup" {
  function_name    = var.project_name
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "lambda_function.lambda_handler"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  timeout          = 60
  memory_size      = 128

  environment {
    variables = {
      DRY_RUN         = tostring(var.dry_run)
      RETENTION_DAYS  = tostring(var.retention_days)
      PROTECT_TAG_KEY = var.protect_tag_key
      SNS_TOPIC_ARN   = aws_sns_topic.alerts.arn
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_iam_role_policy.lambda,
  ]
}
