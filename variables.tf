variable "region" {
  description = "AWS Region"
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "VPC CIDR Block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of AZs (1-3)"
  type        = number
  default     = 2
  validation {
    condition     = var.az_count >= 1 && var.az_count <= 3
    error_message = "AZ count must be between 1 and 3."
  }
}

variable "tags" {
  description = "Common tags"
  type        = map(string)
  default     = {
    Project     = "SalesDataSystem"
    Environment = "Dev"
  }
}

variable "db_name" {
  description = "RDS Database Name"
  type        = string
  default     = "salesdb"
}

variable "db_username" {
  description = "RDS Username"
  type        = string
  default     = "admin"
}

variable "lambda_memory" {
  description = "Lambda Memory Size"
  type        = number
  default     = 128  # Free-tier eligible
}

variable "sns_email" {
  description = "Email for SNS/SES notifications"
  type        = string
  default     = "pinocchio551e2@gmail.com"  
}
