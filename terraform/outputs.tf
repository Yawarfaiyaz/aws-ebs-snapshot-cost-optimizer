output "lambda_function_name" {
  value = aws_lambda_function.cleanup.function_name
}

output "sns_topic_arn" {
  value = aws_sns_topic.alerts.arn
}

output "schedule" {
  value = aws_cloudwatch_event_rule.schedule.schedule_expression
}

output "dry_run" {
  value = var.dry_run
}
