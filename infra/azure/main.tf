terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
}

data "azurerm_client_config" "current" {}

variable "name" {
  type        = string
  description = "Globally unique lowercase alphanumeric prefix, also used for the registry."

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{4,19}$", var.name))
    error_message = "Use 5–20 lowercase letters or digits, starting with a letter."
  }
}

variable "location" {
  type        = string
  description = "Azure region with available AKS node capacity and quota."
  default     = "westeurope"
}

variable "node_vm_size" {
  type        = string
  description = "AKS system node VM size supported by the subscription and region."
  default     = "Standard_D4s_v5"
}

resource "azurerm_resource_group" "lab" {
  name     = "${var.name}-rg"
  location = var.location
  tags     = { environment = "lab" }
}

resource "azurerm_container_registry" "lab" {
  name                = var.name
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  sku                 = "Basic"
  admin_enabled       = false
}

resource "azurerm_kubernetes_cluster" "lab" {
  name                      = "${var.name}-aks"
  location                  = azurerm_resource_group.lab.location
  resource_group_name       = azurerm_resource_group.lab.name
  dns_prefix                = var.name
  sku_tier                  = "Free"
  local_account_disabled    = true
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  default_node_pool {
    name       = "system"
    node_count = 1
    vm_size    = var.node_vm_size
  }

  identity {
    type = "SystemAssigned"
  }

  azure_active_directory_role_based_access_control {
    azure_rbac_enabled = true
    tenant_id          = data.azurerm_client_config.current.tenant_id
  }
}

resource "azurerm_role_assignment" "kubelet_pull" {
  scope                            = azurerm_container_registry.lab.id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_kubernetes_cluster.lab.kubelet_identity[0].object_id
  skip_service_principal_aad_check = true
}

output "resource_group" {
  value = azurerm_resource_group.lab.name
}

output "cluster_name" {
  value = azurerm_kubernetes_cluster.lab.name
}

output "registry_login_server" {
  value = azurerm_container_registry.lab.login_server
}
