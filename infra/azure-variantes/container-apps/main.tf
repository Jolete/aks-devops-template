terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.81.0"
    }
  }
}

provider "azurerm" {
  features {
    servicebus {
      auto_delete_subscription_default_rule = true
    }
  }
  resource_provider_registrations = "none"
}

module "base" {
  source = "../modules/base"

  name                       = var.name
  location                   = var.location
  postgres_admin             = var.postgres_admin
  workload_subnet_delegation = "Microsoft.App/environments"
}

locals {
  workloads = {
    api         = { database = "orders", http = true }
    publisher   = { database = "orders", http = false }
    saga        = { database = "saga", http = false }
    fulfillment = { database = "fulfillment", http = false }
    projection  = { database = "projection", http = true }
  }

  bus_access = {
    publisher_events    = { role = "publisher", direction = "Sender", scope = module.base.events_topic_id }
    saga_events         = { role = "saga", direction = "Receiver", scope = module.base.saga_subscription_id }
    saga_send_events    = { role = "saga", direction = "Sender", scope = module.base.events_topic_id }
    saga_send_commands  = { role = "saga", direction = "Sender", scope = module.base.commands_queue_id }
    fulfillment_receive = { role = "fulfillment", direction = "Receiver", scope = module.base.commands_queue_id }
    fulfillment_events  = { role = "fulfillment", direction = "Sender", scope = module.base.events_topic_id }
    projection_events   = { role = "projection", direction = "Receiver", scope = module.base.projection_subscription_id }
  }

  subscriptions = {
    saga       = module.base.saga_subscription_name
    projection = module.base.projection_subscription_name
  }
}

resource "azurerm_container_registry" "lab" {
  name                                         = "${var.name}aca"
  resource_group_name                          = module.base.resource_group_name
  location                                     = module.base.location
  sku                                          = "Basic"
  admin_enabled                                = false
  azuread_authentication_as_arm_policy_enabled = true
}

resource "azurerm_container_app_environment" "lab" {
  name                       = "${var.name}-env"
  resource_group_name        = module.base.resource_group_name
  location                   = module.base.location
  infrastructure_subnet_id   = module.base.workload_subnet_id
  logs_destination           = "log-analytics"
  log_analytics_workspace_id = module.base.log_analytics_workspace_id

  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }
}

resource "azurerm_user_assigned_identity" "workload" {
  for_each = local.workloads

  name                = "${var.name}-${each.key}"
  resource_group_name = module.base.resource_group_name
  location            = module.base.location
}

resource "azurerm_role_assignment" "pull" {
  for_each = azurerm_user_assigned_identity.workload

  scope                            = azurerm_container_registry.lab.id
  role_definition_name             = "AcrPull"
  principal_id                     = each.value.principal_id
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "bus" {
  for_each = local.bus_access

  scope                            = each.value.scope
  role_definition_name             = "Azure Service Bus Data ${each.value.direction}"
  principal_id                     = azurerm_user_assigned_identity.workload[each.value.role].principal_id
  skip_service_principal_aad_check = true
}

resource "azurerm_container_app" "workload" {
  for_each = { for role, config in local.workloads : role => config if var.image_digest != null }

  name                         = "${var.name}-${each.key}"
  resource_group_name          = module.base.resource_group_name
  container_app_environment_id = azurerm_container_app_environment.lab.id
  workload_profile_name        = "Consumption"
  revision_mode                = "Single"

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.workload[each.key].id]
  }

  registry {
    server   = azurerm_container_registry.lab.login_server
    identity = azurerm_user_assigned_identity.workload[each.key].id
  }

  dynamic "ingress" {
    for_each = each.value.http ? [1] : []

    content {
      external_enabled = var.public_ingress
      target_port      = 8080
      transport        = "http"

      traffic_weight {
        percentage      = 100
        latest_revision = true
      }
    }
  }

  template {
    # Polling outboxes need a running instance even when inbound queues are empty.
    min_replicas = 1
    max_replicas = 1

    container {
      name   = each.key
      image  = "${azurerm_container_registry.lab.login_server}/${var.image_repository}@${var.image_digest}"
      cpu    = 0.25
      memory = "0.5Gi"

      dynamic "env" {
        for_each = merge(
          {
            WORKLOAD_ROLE                         = each.key
            AZURE_CLIENT_ID                       = azurerm_user_assigned_identity.workload[each.key].client_id
            PGHOST                                = module.base.postgres_fqdn
            PGPORT                                = "5432"
            PGDATABASE                            = module.base.database_names[each.value.database]
            PGUSER                                = azurerm_user_assigned_identity.workload[each.key].name
            PGSSLMODE                             = "require"
            APPLICATIONINSIGHTS_CONNECTION_STRING = module.base.application_insights_connection_string
          },
          each.value.http ? { PORT = "8080" } : {},
          each.key == "api" ? {} : {
            SERVICE_BUS_FULLY_QUALIFIED_NAMESPACE = module.base.service_bus_namespace_fqdn
            SERVICE_BUS_COMMANDS_QUEUE            = module.base.commands_queue_name
            SERVICE_BUS_EVENTS_TOPIC              = module.base.events_topic_name
          },
          contains(keys(local.subscriptions), each.key) ? {
            SERVICE_BUS_SUBSCRIPTION = local.subscriptions[each.key]
          } : {}
        )

        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "readiness_probe" {
        for_each = each.value.http ? [1] : []

        content {
          transport               = "HTTP"
          port                    = 8080
          path                    = "/healthz"
          interval_seconds        = 5
          success_count_threshold = 1
        }
      }
    }
  }

  depends_on = [azurerm_role_assignment.pull, azurerm_role_assignment.bus]
}
