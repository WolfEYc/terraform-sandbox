terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}

variable "env" {
  description = "environment to deploy to"
  type        = string
}

variable "region" {
  description = "region to deploy to"
  type        = string
  default     = "us-east-1"
}

variable "app_name" {
  description = "app name, used for grouping purposes"
  type        = string
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Terraform   = "true"
      Project     = var.app_name
      Environment = var.env
      Owner       = "isaacw"
    }
  }
}

