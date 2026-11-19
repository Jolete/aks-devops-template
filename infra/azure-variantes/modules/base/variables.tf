variable "name" {
  type        = string
  description = "Prefijo de nombres de la infraestructura."
}

variable "location" {
  type        = string
  description = "Región de Azure en la que se crean los recursos."
}

variable "postgres_admin" {
  type = object({
    object_id      = string
    principal_name = string
    principal_type = string
  })
  description = "Entidad de Microsoft Entra que administra PostgreSQL."
}

variable "workload_subnet_delegation" {
  type        = string
  description = "Delegación de la subred donde se ejecutan las cargas."
}
