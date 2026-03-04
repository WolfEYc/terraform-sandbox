terraform {
  backend "remote" {
    organization = "wolfey-code"
    workspaces {
      name = "basics-3"
    }
  }
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

provider "aws" {
  region = "us-east-1"
}

data "aws_vpc" "default_vpc" {
  default = true
}

data "aws_subnet_ids" "default_subnet" {
  vpc_id = data.aws_vpc.default_vpc.id
}

resource "aws_security_group" "instances" {
  name = "instance-sg"
}

resource "aws_security_group_rule" "allow_http_inbound" {
  type              = "ingress"
  security_group_id = aws_security_group.instances.id

  from_port   = 8080
  to_port     = 8080
  protocol    = "tcp"
  cidr_blocks = ["0.0.0.0/0"]
}

resource "aws_security_group" "alb" {
  name = "alb-sg"
}

resource "aws_security_group_rule" "alb_allow_http_inbound" {
  type              = "ingress"
  security_group_id = aws_security_group.alb.id

  from_port   = 80
  to_port     = 80
  protocol    = "tcp"
  cidr_blocks = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "alb_allow_all_outbound" {
  type              = "egress"
  security_group_id = aws_security_group.alb.id

  from_port   = 0
  to_port     = 0
  protocol    = "-1"
  cidr_blocks = ["0.0.0.0/0"]
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

data "cloudflare_zone" "main" {
  name = "wolfeycode.com"
}
resource "cloudflare_record" "app" {
  zone_id = data.cloudflare_zone.main.id
  name    = "app"
  value   = aws_lb.lb.dns_name
  type    = "CNAME"
  proxied = true
}

resource "aws_acm_certificate" "app" {
  domain_name       = "app.wolfeycode.com"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "cloudflare_record" "cert_validation" {
  zone_id = data.cloudflare_zone.main.id
  name    = aws_acm_certificate.app.domain_validation_options[0].resource_record_name
  value   = aws_acm_certificate.app.domain_validation_options[0].resource_record_value
  type    = aws_acm_certificate.app.domain_validation_options[0].resource_record_type
  ttl     = 60
  proxied = false
}

resource "aws_acm_certificate_validation" "app" {
  certificate_arn         = aws_acm_certificate.app.arn
  validation_record_fqdns = [cloudflare_record.cert_validation.hostname]
}

resource "aws_lb" "lb" {
  name               = "web-lb"
  load_balancer_type = "application"
  subnets            = data.aws_subnet_ids.default_subnet.ids
  security_groups    = [aws_security_group.alb.id]
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.lb.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn   = aws_acm_certificate_validation.app.certificate_arn

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "404: page not found"
      status_code  = 404
    }
  }
}

resource "aws_lb_listener_rule" "instances" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 100

  condition {
    path_pattern {
      values = ["*"]
    }
  }
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.instances.arn
  }
}

resource "aws_lb_target_group" "instances" {
  name     = "instances-tg"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default_vpc.id

  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
    timeout             = 3
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_instance" "instance_1" {
  ami             = "ami-011899242bb902164"
  instance_type   = "t3.micro"
  security_groups = [aws_security_group.instances.name]
  user_data       = <<-EOF
      #!/bin/bash
      echo "Hello, World 1" > index.html
      python3 -m http.server 8080 &
      EOF
}
resource "aws_lb_target_group_attachment" "instance_1" {
  target_group_arn = aws_lb_target_group.instances.arn
  target_id        = aws_instance.instance_1.id
  port             = 8080
}

resource "aws_instance" "instance_2" {
  ami             = "ami-011899242bb902164"
  instance_type   = "t3.micro"
  security_groups = [aws_security_group.instances.name]
  user_data       = <<-EOF
      #!/bin/bash
      echo "Hello, World 1" > index.html
      python3 -m http.server 8080 &
      EOF
}
resource "aws_lb_target_group_attachment" "instance_2" {
  target_group_arn = aws_lb_target_group.instances.arn
  target_id        = aws_instance.instance_2.id
  port             = 8080
}

resource "aws_db_instance" "db_instance" {
  allocated_storage   = 20
  storage_type        = "standard"
  engine              = "postgres"
  engine_version      = "12.5"
  instance_class      = "db.t3.micro"
  username            = "foo"
  password            = "foobarbaz"
  skip_final_snapshot = true
}
