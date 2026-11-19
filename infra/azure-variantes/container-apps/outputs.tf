output "resource_group_name" {
  value = module.base.resource_group_name
}

output "registry_id" {
  description = "Scope for the separate image publishing identity."
  value       = azurerm_container_registry.lab.id
}

output "registry_login_server" {
  value = azurerm_container_registry.lab.login_server
}

output "workload_identities" {
  description = "Register each PostgreSQL role by object ID, using the identity name as its database username."
  value = {
    for role, identity in azurerm_user_assigned_identity.workload : role => {
      name         = identity.name
      client_id    = identity.client_id
      principal_id = identity.principal_id
      database     = module.base.database_names[local.workloads[role].database]
    }
  }
}

output "postgres_fqdn" {
  value = module.base.postgres_fqdn
}

output "http_urls" {
  description = "API and projection URLs. Reachable only within the Container Apps environment unless public_ingress is enabled."
  value = {
    for role, app in azurerm_container_app.workload : role => "https://${app.ingress[0].fqdn}"
    if local.workloads[role].http
  }
}
