
variable "cloudflare_zone_id" {
  description = "zone_id of domain you wish to use from cflare"
  type        = string
}


data "cloudflare_zone" "main" {
  zone_id = var.cloudflare_zone_id
}

# app.wolfeycode.com -> aws-lb-3847934.us-east-1.aws.com (some aws assigned domain for the lb)
resource "cloudflare_dns_record" "app" {
  zone_id = data.cloudflare_zone.main.id
  name    = var.app_name
  content = aws_lb.lb.dns_name
  type    = "CNAME"
  proxied = true
  ttl     = 1
}

# SSL certs
resource "aws_acm_certificate" "app" {
  domain_name       = "${cloudflare_dns_record.app.name}.${data.cloudflare_zone.main.name}"
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
