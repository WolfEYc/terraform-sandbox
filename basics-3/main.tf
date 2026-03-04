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

  default_tags {
    tags = {
      Terraform   = "true"
      Project     = "basics-3"
      Environment = "dev"
      Owner       = "isaacw"
    }
  }
}

resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
}

data "aws_availability_zones" "available" {
  state = "available"
}
resource "aws_subnet" "public" {
  count                   = 2 # one per AZ
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0" # allow inbound traffic from anywhere
    gateway_id = aws_internet_gateway.gw.id
  }
}

resource "aws_route_table_association" "public_assoc" { # map public subnet to public route table
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_subnet" "private" {
  count                   = 2 # one per AZ
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(aws_vpc.main.cidr_block, 8, length(aws_subnet.public) + count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = false
}

provider "cloudflare" {}

data "cloudflare_zone" "main" {
  zone_id = "c4f956c7bfc63cd0b0751ebf00d38134"
}
resource "cloudflare_dns_record" "app" {
  zone_id = data.cloudflare_zone.main.id
  name    = "app"
  content = aws_lb.lb.dns_name
  type    = "CNAME"
  proxied = true
  ttl     = 1
}

resource "aws_acm_certificate" "app" {
  domain_name       = "app.wolfeycode.com"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "cloudflare_dns_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.app.domain_validation_options :
    dvo.domain_name => dvo
  }

  zone_id = data.cloudflare_zone.main.id
  name    = each.value.resource_record_name
  content = each.value.resource_record_value
  type    = each.value.resource_record_type
  ttl     = 60
  proxied = false
}

resource "aws_acm_certificate_validation" "app" {
  certificate_arn         = aws_acm_certificate.app.arn
  validation_record_fqdns = [for record in cloudflare_dns_record.cert_validation : record.name]
}

resource "aws_security_group" "alb" {
  name   = "alb-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb" "lb" {
  name               = "web-lb"
  load_balancer_type = "application"
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.alb.id]
  internal           = false
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
  vpc_id   = aws_vpc.main.id

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

resource "aws_security_group" "instances" {
  name   = "instance-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "instance_1" {
  ami                    = "ami-011899242bb902164"
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.private[0].id
  vpc_security_group_ids = [aws_security_group.instances.id]
  user_data              = <<-EOF
      #!/bin/bash
      echo "Hello, World 1" > index.html
      python3 -m http.server 8080 &
      EOF
  tags = {
    Name = "basic-1"
  }
}
resource "aws_lb_target_group_attachment" "instance_1" {
  target_group_arn = aws_lb_target_group.instances.arn
  target_id        = aws_instance.instance_1.id
  port             = 8080
}

resource "aws_instance" "instance_2" {
  ami                    = "ami-011899242bb902164"
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.private[1].id
  vpc_security_group_ids = [aws_security_group.instances.id]
  user_data              = <<-EOF
      #!/bin/bash
      echo "Hello, World 1" > index.html
      python3 -m http.server 8080 &
      EOF
  tags = {
    Name = "basic-2"
  }
}
resource "aws_lb_target_group_attachment" "instance_2" {
  target_group_arn = aws_lb_target_group.instances.arn
  target_id        = aws_instance.instance_2.id
  port             = 8080
}

resource "random_password" "db" {
  length  = 16
  special = true
}

resource "aws_secretsmanager_secret" "db" {
  name = "basics-3-db-password"
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id     = aws_secretsmanager_secret.db.id
  secret_string = random_password.db.result
}

resource "aws_db_instance" "db_instance" {
  allocated_storage   = 20
  storage_type        = "standard"
  engine              = "postgres"
  engine_version      = "18.3"
  instance_class      = "db.t3.micro"
  username            = "foo"
  password            = aws_secretsmanager_secret_version.db.secret_string
  skip_final_snapshot = true
}
