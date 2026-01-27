variable "aws_region" {
  type        = string
  default     = "us-east-2"
  description = "The ARN of the S3 bucket to use for the application."
}
variable "aws_s3_bucket_arn" {
  type        = string
  description = "The ARN of the S3 bucket to use for the application."
}

variable "aws_public_subnet_id" {
  type        = string
  description = "The ID of the public subnet to use for the application."
}

variable "aws_private_subnet_id" {
  type        = string
  description = "The ID of the private subnet to use for the application."
}

variable "aws_vpc_id" {
  type        = string
  description = "The ID of the VPC to use for the application."
}

variable "app_name" {
  type        = string
  description = "The name of the application."
}
