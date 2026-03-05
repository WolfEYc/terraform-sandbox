
terraform {
  backend "remote" {
    organization = "wolfey-code"
    workspaces {
      name = "modules-4"
    }
  }
}

variable "cloudflare_zone_id" {
  type = string
}

locals {
  app_name = "module-demo"
  env      = "dev"
}

module "web_app_1" {
  source = "../web-app-module"

  env                = local.env
  cloudflare_zone_id = var.cloudflare_zone_id
  app_name           = local.app_name
}
