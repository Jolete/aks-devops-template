terraform {
  required_version = ">= 1.5.0"
}

variable "environment" {
  type        = string
  description = "Name of the local Terraform exercise."
  default     = "local"
}

resource "terraform_data" "deployment" {
  input = {
    environment = var.environment
    replicas    = 2
  }
}

output "deployment" {
  value = terraform_data.deployment.output
}
