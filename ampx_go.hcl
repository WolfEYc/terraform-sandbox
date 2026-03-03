provider "aws" {
  region = "us-east-1"
}

resource "aws_vpc" "ampx_go" {
  cidr_block = "10.0.0.0/16"
}

resource "aws_subnet" "public" {
  count                   = 2  # one per AZ
  vpc_id                  = aws_vpc.ampx_go.id
  cidr_block              = cidrsubnet(aws_vpc.ampx_go.cidr_block, 8, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
}

resource "aws_subnet" "private" {
  count                   = 2  # one per AZ
  vpc_id                  = aws_vpc.ampx_go.id
  cidr_block              = cidrsubnet(aws_vpc.ampx_go.cidr_block, 8, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = false
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.ampx_go.id
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.ampx_go.id

  route {
    cidr_block = "0.0.0.0/0" # allow inbound traffic from anywhere
    gateway_id = aws_internet_gateway.gw.id
  }
}

resource "aws_route_table_association" "public_assoc" { # map public subnet to public route table
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# DNS
resource "aws_route53_zone" "ampx_go" {
  name = "amerapexgo.com"
}

# DNS cert
resource "aws_acm_certificate" "ampx_go" {
  domain_name       = "amerapexgo.com"
  validation_method = "DNS"

  # Optionally, subject alternative names
  subject_alternative_names = ["www.amerapexgo.com"]
}

resource "aws_route53_record" "ampx_go_cert_temp" {
  for_each = {
    for dvo in aws_acm_certificate.api_cert.domain_validation_options : dvo.domain_name => dvo
  }

  zone_id = aws_route53_zone.main.zone_id
  name    = each.value.resource_record_name
  type    = each.value.resource_record_type
  records = [each.value.resource_record_value]
  ttl     = 60
}

# Wait for validation
resource "aws_acm_certificate_validation" "ampx_go" {
  certificate_arn         = aws_acm_certificate.ampx_go.arn
  validation_record_fqdns = [for record in aws_route53_record.ampx_go_cert_temp : record.fqdn]
}
# END DNS cert

# Security
resource "aws_iam_role" "ec2_role" {
  name = "ampx_go_ec2_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = { Service = "ec2.amazonaws.com" },
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_attach" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ampx_go_ec2_profile"
  role = aws_iam_role.ec2_role.name
}

resource "aws_security_group" "ampx_go_lb" {
  name        = "ampx_go_lb_sg"
  description = "Allow HTTP/HTTPS from internet"
  vpc_id      = aws_vpc.ampx_go.id

  # HTTP
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTPS
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow outbound to app instances
  egress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }
}

resource "aws_security_group" "ampx_go_ec2" {
  name   = "ampx_go_ec2_sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.ampx_go_lb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
#

# DNS record pointing amerapexgo.com → LB
resource "aws_route53_record" "ampx_go" {
  zone_id = aws_route53_zone.ampx_go.zone_id
  name    = "amerapexgo.com"
  type    = "A"

  alias {
    name                   = aws_lb.ampx_go.dns_name
    zone_id                = aws_lb.ampx_go.zone_id
    evaluate_target_health = true
  }
}

resource "aws_lb" "ampx_go" {
  name               = "ampx_go_lb"
  internal           = false        # internet-facing
  load_balancer_type = "application"
  security_groups    = [aws_security_group.ampx_go_lb.id]
  subnets            = [aws_subnet.public[*].id]

  enable_deletion_protection = false
}

resource "aws_lb_listener" "ampx_go" {
  load_balancer_arn = aws_lb.ampx_go.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2023-03"
  certificate_arn   = aws_acm_certificate.api_cert.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ampx_go.arn
  }
}

resource "aws_lb_target_group" "ampx_go" {
  name     = "ampx_go_tg"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = aws_vpc.ampx_go.id

  health_check {
    path                = "/health"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

data "aws_ami" "amazon_linux_2_arm" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-arm64-gp2"]
  }
}

# EC2 Auto Scaling Group
resource "aws_launch_template" "ampx_go" {
  name_prefix   = "ampx_go-"
  image_id      = data.aws_ami.amazon_linux_2_arm.id
  instance_type = "t4g.medium"
  iam_instance_profile {
    name = aws_iam_instance_profile.ampx_go.name
  }
  vpc_security_group_ids = [
    aws_security_group.ampx_go_ec2.id
  ]
  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "ampx_go"
    }
  }
  user_data =  base64encode(<<-EOF
    #!/bin/bash
    yum update -y

    # create app directory
    mkdir -p /usr/local/bin

    # systemd service
    cat <<EOT > /etc/systemd/system/ampx_go.service
    [Unit]
    Description=ampx go app
    After=network.target

    [Service]
    ExecStart=/usr/local/bin/ampx_go
    Restart=always
    User=ec2-user

    [Install]
    WantedBy=multi-user.target
    EOT

    systemctl daemon-reload
    systemctl enable ampx_go
  EOF
  )
}

resource "aws_autoscaling_group" "ampx_go" {
  desired_capacity     = 2
  max_size             = 5
  min_size             = 2
  launch_template {
    id      = aws_launch_template.ampx_go.id
    version = "$Latest"
  }
  vpc_zone_identifier = aws_subnet.private[*].id
  target_group_arns = [aws_lb_target_group.ampx_go.arn]
}
