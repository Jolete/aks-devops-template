terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.81.0"
    }
  }
}

data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "lab" {
  name     = "${var.name}-rg"
  location = var.location
}

resource "azurerm_virtual_network" "lab" {
  name                = "${var.name}-vnet"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  address_space       = ["10.42.0.0/16"]
}

resource "azurerm_subnet" "workload" {
  name                 = "workloads"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = ["10.42.0.0/23"]

  delegation {
    name = "workloads"
    service_delegation {
      name    = var.workload_subnet_delegation
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "postgres" {
  name                 = "postgres"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = ["10.42.2.0/27"]

  delegation {
    name = "postgres"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_private_dns_zone" "postgres" {
  name                = "${var.name}.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.lab.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  name                  = "postgres-to-vnet"
  resource_group_name   = azurerm_resource_group.lab.name
  private_dns_zone_name = azurerm_private_dns_zone.postgres.name
  virtual_network_id    = azurerm_virtual_network.lab.id
}

resource "azurerm_postgresql_flexible_server" "lab" {
  name                          = "${var.name}-pg"
  resource_group_name           = azurerm_resource_group.lab.name
  location                      = azurerm_resource_group.lab.location
  version                       = "16"
  sku_name                      = "B_Standard_B1ms"
  storage_mb                    = 32768
  backup_retention_days         = 7
  public_network_access_enabled = false
  delegated_subnet_id           = azurerm_subnet.postgres.id
  private_dns_zone_id           = azurerm_private_dns_zone.postgres.id

  authentication {
    active_directory_auth_enabled = true
    password_auth_enabled         = false
    tenant_id                     = data.azurerm_client_config.current.tenant_id
  }

  depends_on = [azurerm_private_dns_zone_virtual_network_link.postgres]
}

resource "azurerm_postgresql_flexible_server_active_directory_administrator" "lab" {
  server_name         = azurerm_postgresql_flexible_server.lab.name
  resource_group_name = azurerm_resource_group.lab.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  object_id           = var.postgres_admin.object_id
  principal_name      = var.postgres_admin.principal_name
  principal_type      = var.postgres_admin.principal_type
}

resource "azurerm_postgresql_flexible_server_database" "service" {
  for_each  = toset(["orders", "saga", "fulfillment", "projection"])
  name      = each.key
  server_id = azurerm_postgresql_flexible_server.lab.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

resource "azurerm_servicebus_namespace" "lab" {
  name                          = "${var.name}-bus"
  resource_group_name           = azurerm_resource_group.lab.name
  location                      = azurerm_resource_group.lab.location
  sku                           = "Standard"
  local_auth_enabled            = false
  public_network_access_enabled = true
  minimum_tls_version           = "1.2"
}

resource "azurerm_servicebus_queue" "commands" {
  name                                 = "fulfillment-commands"
  namespace_id                         = azurerm_servicebus_namespace.lab.id
  max_delivery_count                   = 5
  lock_duration                        = "PT1M"
  dead_lettering_on_message_expiration = true
}

resource "azurerm_servicebus_topic" "events" {
  name         = "order-events"
  namespace_id = azurerm_servicebus_namespace.lab.id
}

locals {
  subscriptions = {
    saga       = "eventType IN ('order.placed', 'fulfillment.completed', 'fulfillment.rejected', 'fulfillment.released')"
    projection = "eventType IN ('saga.completed', 'saga.compensated')"
  }
}

resource "azurerm_servicebus_subscription" "consumer" {
  for_each = local.subscriptions

  name                                 = each.key
  topic_id                             = azurerm_servicebus_topic.events.id
  max_delivery_count                   = 5
  lock_duration                        = "PT1M"
  dead_lettering_on_message_expiration = true
}

resource "azurerm_servicebus_subscription_rule" "consumer" {
  for_each = local.subscriptions

  name            = "event-type"
  subscription_id = azurerm_servicebus_subscription.consumer[each.key].id
  filter_type     = "SqlFilter"
  sql_filter      = each.value
}

resource "azurerm_log_analytics_workspace" "lab" {
  name                = "${var.name}-logs"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_application_insights" "lab" {
  name                = "${var.name}-insights"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  workspace_id        = azurerm_log_analytics_workspace.lab.id
  application_type    = "web"
}
