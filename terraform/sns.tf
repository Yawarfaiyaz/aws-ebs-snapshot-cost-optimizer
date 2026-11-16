resource "aws_sns_topic" "alerts" {
  name = "${var.project_name}-alerts"
}

# AWS sends a confirmation email first. You must click "Confirm subscription".
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}
