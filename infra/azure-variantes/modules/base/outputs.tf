output "resource_group_name" {
  value = azurerm_resource_group.lab.name
}

output "location" {
  value = azurerm_resource_group.lab.location
}

output "workload_subnet_id" {
  value = azurerm_subnet.workload.id
}

output "log_analytics_workspace_id" {
  value = azurerm_log_analytics_workspace.lab.id
}

output "application_insights_connection_string" {
  value     = azurerm_application_insights.lab.connection_string
  sensitive = true
}

output "service_bus_namespace_fqdn" {
  value = trimsuffix(trimprefix(azurerm_servicebus_namespace.lab.endpoint, "https://"), "/")
}

output "commands_queue_name" {
  value = azurerm_servicebus_queue.commands.name
}

output "commands_queue_id" {
  value = azurerm_servicebus_queue.commands.id
}

output "events_topic_name" {
  value = azurerm_servicebus_topic.events.name
}

output "events_topic_id" {
  value = azurerm_servicebus_topic.events.id
}

output "saga_subscription_name" {
  value = azurerm_servicebus_subscription.consumer["saga"].name
}

output "saga_subscription_id" {
  value = azurerm_servicebus_subscription.consumer["saga"].id
}

output "projection_subscription_name" {
  value = azurerm_servicebus_subscription.consumer["projection"].name
}

output "projection_subscription_id" {
  value = azurerm_servicebus_subscription.consumer["projection"].id
}

output "postgres_fqdn" {
  value = azurerm_postgresql_flexible_server.lab.fqdn
}

output "database_names" {
  value = { for role, database in azurerm_postgresql_flexible_server_database.service : role => database.name }
}
