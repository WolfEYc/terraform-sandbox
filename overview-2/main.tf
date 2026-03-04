terraform {
  backend "remote" {
    organization = "wolfey-code"
    workspaces {
      name = "overview-2"
    }
  }
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

resource "aws_instance" "example" {
  ami           = "ami-011899242bb902164"
  instance_type = "t3.micro"
}
