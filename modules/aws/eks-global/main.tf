terraform {
  required_version = "0.15.3"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "3.47.0"
    }
  }
}

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}
