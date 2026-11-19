variable "name" {
  type        = string
  description = "Globally unique lowercase alphanumeric prefix. Used to name Azure resources."

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{4,17}$", var.name))
    error_message = "Use 5–18 lowercase letters or digits, starting with a letter."
  }
}

variable "location" {
  type        = string
  description = "Azure region for the Container Apps lab."
  default     = "westeurope"
}

variable "postgres_admin" {
  type = object({
    object_id      = string
    principal_name = string
    principal_type = string
  })
  description = "Microsoft Entra principal used to set up PostgreSQL schemas and database grants."
}

variable "image_repository" {
  type        = string
  description = "ACR repository for the Azure-adapted image."
  default     = "orders-lab"

  validation {
    condition     = can(regex("^[a-z0-9]+([._/-][a-z0-9]+)*$", var.image_repository))
    error_message = "Use a lowercase image repository name without a registry, tag, or digest."
  }
}

variable "image_digest" {
  type        = string
  description = "Digest of an Azure-adapted Service Bus and PostgreSQL image. Leave null to deploy the foundation only. The local RabbitMQ and SQLite image is incompatible."
  default     = null

  validation {
    condition     = var.image_digest == null || can(regex("^sha256:[0-9a-f]{64}$", var.image_digest))
    error_message = "Use a sha256 digest with 64 lowercase hexadecimal characters or leave the value null."
  }
}

variable "public_ingress" {
  type        = bool
  description = "Expose the API and projection to the internet. Leave false for environment-local ingress."
  default     = false
}
