output "rds_endpoint" {
  value = aws_db_instance.sales_rds.endpoint
}

output "lambda_arn" {
  value = aws_lambda_function.sales_processor.arn
}

output "sns_topic_arn" {
  value = aws_sns_topic.sales_notifications.arn
}
