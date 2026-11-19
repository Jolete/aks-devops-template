mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id = "00000000-0000-0000-0000-000000000001"
    }
  }
}

variables {
  name = "pedidoslab123"
  postgres_admin = {
    object_id      = "00000000-0000-0000-0000-000000000002"
    principal_name = "test-admins"
    principal_type = "Group"
  }
}

run "foundation" {
  command = plan

  assert {
    condition     = length(azurerm_container_app.workload) == 0 && length(azurerm_user_assigned_identity.workload) == 5
    error_message = "Foundation should provision five identities and no applications."
  }
}

run "workloads" {
  command = plan

  variables {
    image_digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }

  assert {
    condition     = length(azurerm_container_app.workload) == 5
    error_message = "A compatible image digest should enable all five applications."
  }

  assert {
    condition     = alltrue([for app in azurerm_container_app.workload : app.template[0].min_replicas == 1])
    error_message = "Outbox processes must not scale to zero."
  }

  assert {
    condition     = length(azurerm_container_app.workload["publisher"].ingress) == 0 && azurerm_container_app.workload["api"].ingress[0].external_enabled == false
    error_message = "Public ingress must be opt-in."
  }
}
