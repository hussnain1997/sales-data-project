data "aws_availability_zones" "available" {}

locals {
  azs             = slice(data.aws_availability_zones.available.names, 0, var.az_count)
  public_subnets  = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, i)]
  private_subnets = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, i + var.az_count)]
}

# VPC
resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr
  tags       = merge(var.tags, { Name = "SalesVPC" })
}

# Public Subnets
resource "aws_subnet" "public" {
  count                   = var.az_count
  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.public_subnets[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true
  tags                    = merge(var.tags, { Name = "PublicSubnet-${count.index}" })
}

# Private Subnets
resource "aws_subnet" "private" {
  count             = var.az_count
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.private_subnets[count.index]
  availability_zone = local.azs[count.index]
  tags              = merge(var.tags, { Name = "PrivateSubnet-${count.index}" })
}

# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = merge(var.tags, { Name = "SalesIGW" })
}

# Route Tables
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = merge(var.tags, { Name = "PublicRT" })
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = merge(var.tags, { Name = "PrivateRT" })
}

# Route Table Associations
resource "aws_route_table_association" "public" {
  count          = var.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = var.az_count
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# Elastic IP for NAT
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = merge(var.tags, { Name = "NatEIP" })
}

# NAT Gateway (in first public subnet)
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = merge(var.tags, { Name = "SalesNAT" })
}

# Add NAT route to private RT
resource "aws_route" "private_nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat.id
}

# Random Password for RDS
resource "random_password" "db_password" {
  length  = 16
  special = false
}

# Secrets Manager for RDS Credentials
resource "aws_secretsmanager_secret" "rds_creds" {
  name = "sales-rds-creds"
  tags = merge(var.tags, { Name = "RDSCredsSecret" })
}

resource "aws_secretsmanager_secret_version" "rds_creds_version" {
  secret_id = aws_secretsmanager_secret.rds_creds.id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db_password.result
    host     = aws_db_instance.sales_rds.address
    dbname   = var.db_name
  })
}

# RDS MySQL
resource "aws_db_instance" "sales_rds" {
  allocated_storage    = 20  # Free-tier
  storage_type         = "gp2"
  engine               = "mysql"
  engine_version       = "8.0"
  instance_class       = "db.t3.micro"  # Free-tier
  db_name              = var.db_name
  username             = var.db_username
  password             = random_password.db_password.result
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  db_subnet_group_name = aws_db_subnet_group.rds_subnet_group.name
  skip_final_snapshot  = true
  publicly_accessible  = false
  tags                 = merge(var.tags, { Name = "SalesRDS" })
}

resource "aws_db_subnet_group" "rds_subnet_group" {
  name       = "sales-rds-subnet-group"
  subnet_ids = aws_subnet.private[*].id
  tags       = merge(var.tags, { Name = "RDSSubnetGroup" })
}

# SNS Topic
resource "aws_sns_topic" "sales_notifications" {
  name = "sales-notifications"
  tags = merge(var.tags, { Name = "SalesSNS" })
}

resource "aws_sns_topic_subscription" "email_sub" {
  topic_arn = aws_sns_topic.sales_notifications.arn
  protocol  = "email"
  endpoint  = var.sns_email
}

# Lambda Role
resource "aws_iam_role" "lambda_role" {
  name = "sales-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
  tags = merge(var.tags, { Name = "LambdaRole" })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_policy" "lambda_policy" {
  name   = "sales-lambda-policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.rds_creds.arn
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.sales_notifications.arn
      },
      {
        Effect   = "Allow"
        Action   = ["ses:SendEmail", "ses:SendRawEmail"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_custom" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.lambda_policy.arn
}

# Zip Lambda Code
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda_code"
  output_path = "${path.module}/lambda.zip"
}

# Lambda Function
resource "aws_lambda_function" "sales_processor" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "sales-data-processor"
  role             = aws_iam_role.lambda_role.arn
  handler          = "main.lambda_handler"
  runtime          = "python3.12"
  memory_size      = var.lambda_memory
  timeout          = 30
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  vpc_config {
    subnet_ids         = aws_subnet.private[*].id
    security_group_ids = [aws_security_group.lambda_sg.id]
  }

  depends_on = [aws_db_instance.sales_rds]  # Ensure RDS is ready
  tags       = merge(var.tags, { Name = "SalesLambda" })
}

# Initial Data Population (Invoke Lambda once after creation with 'init' payload)
resource "aws_lambda_invocation" "initial_populate" {
  function_name = aws_lambda_function.sales_processor.function_name
  input         = jsonencode({ mode = "init" })  # Payload to trigger initial insert

  depends_on = [aws_lambda_function.sales_processor]
}

# EventBridge Rule (Daily Trigger)
resource "aws_cloudwatch_event_rule" "daily_trigger" {
  name                = "daily-sales-process"
  schedule_expression = "cron(0 0 * * ? *)"  # Daily at midnight UTC
  tags                = merge(var.tags, { Name = "DailyTrigger" })
}

resource "aws_cloudwatch_event_target" "lambda_target" {
  rule      = aws_cloudwatch_event_rule.daily_trigger.name
  target_id = "sales-lambda"
  arn       = aws_lambda_function.sales_processor.arn
  input     = jsonencode({ mode = "daily" })  # Payload for daily process
}

# Lambda Permission for EventBridge
resource "aws_lambda_permission" "eventbridge_invoke" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.sales_processor.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.daily_trigger.arn
}

# SSM Parameters (e.g., for VPC ID, Subnet IDs)
resource "aws_ssm_parameter" "vpc_id" {
  name  = "/sales/vpc_id"
  type  = "String"
  value = aws_vpc.main.id
  tags  = var.tags
}

resource "aws_ssm_parameter" "private_subnet_ids" {
  name  = "/sales/private_subnet_ids"
  type  = "StringList"
  value = join(",", aws_subnet.private[*].id)
  tags  = var.tags
}

# Outputs (for verification)
output "rds_endpoint" {
  value = aws_db_instance.sales_rds.endpoint
}

output "lambda_arn" {
  value = aws_lambda_function.sales_processor.arn
}

output "sns_topic_arn" {
  value = aws_sns_topic.sales_notifications.arn
}
