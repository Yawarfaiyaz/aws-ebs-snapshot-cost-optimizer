variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "ap-southeast-2"
}

variable "project_name" {
  description = "Prefix for every resource name"
  type        = string
  default     = "ebs-snapshot-cleanup"
}

variable "alert_email" {
  description = "Email address that receives cleanup reports and alarms"
  type        = string
}

variable "dry_run" {
  description = "true = only report, false = really delete snapshots"
  type        = bool
  default     = true
}

variable "retention_days" {
  description = "Never delete snapshots younger than this many days"
  type        = number
  default     = 30
}

variable "protect_tag_key" {
  description = "Snapshots with this tag set to true are never deleted"
  type        = string
  default     = "DoNotDelete"
}

variable "schedule_expression" {
  description = "When the cleanup runs (EventBridge syntax, UTC)"
  type        = string
  default     = "cron(30 20 * * ? *)" # 20:30 UTC = 2:00 AM IST daily (region does not change the time)
}

variable "monthly_budget_usd" {
  description = "Monthly AWS budget in USD; you get an email at 80% and 100%"
  type        = number
  default     = 5
}
