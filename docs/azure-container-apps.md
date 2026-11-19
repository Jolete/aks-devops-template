# Terraform para la variante Azure Container Apps

La raíz [infra/azure-variantes/container-apps](../infra/azure-variantes/container-apps/) gestiona la infraestructura de la [arquitectura de pedidos](azure-variantes.md#1-azure-container-apps). Se eligió Container Apps porque conserva los cinco procesos del ejemplo local y permite usar una imagen común con una identidad independiente por proceso.

| Servicio | Qué crea Terraform |
| --- | --- |
| Container Apps | Entorno con integración de red y aplicaciones separadas para API, publicador, Saga, preparación y proyección cuando se suministra una imagen. Solo API y proyección tienen ingreso HTTP. |
| Service Bus | Namespace Standard, cola de comandos, topic de eventos y suscripciones filtradas de Saga y proyección. La cola y las suscripciones tienen un límite de entregas y cola de fallidos. |
| PostgreSQL Flexible Server | Servidor privado con DNS enlazado a la red virtual, autenticación de Microsoft Entra y bases separadas para pedidos, Saga, preparación y proyección. API y publicador comparten la base de pedidos. |
| Azure Container Registry | Registro Basic con repositorios autenticados y descarga por identidad administrada. |
| Azure Monitor | Área de trabajo de Log Analytics y Application Insights para recibir la telemetría de la aplicación. |

## Preparar una primera ejecución

Usa Terraform y Azure CLI desde Terminal en macOS o Ubuntu en WSL 2. Elige una suscripción de pruebas y una identidad autorizada para crear recursos y asignar roles. La raíz no registra proveedores automáticamente. La suscripción debe tener disponibles los proveedores de Container Apps, ACR, Service Bus, PostgreSQL, red, identidades y observabilidad.

```bash
az login
az account set --subscription '<suscripcion-de-pruebas>'
export ARM_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
terraform -chdir=infra/azure-variantes/container-apps init
terraform -chdir=infra/azure-variantes/container-apps validate
```

Crea un archivo local `lab.tfvars` dentro de la raíz de Terraform, a partir de este ejemplo. Usa un prefijo disponible globalmente de 5 a 18 caracteres y una región con capacidad para los recursos.

```hcl
name     = "pedidoslab123"
location = "westeurope"

postgres_admin = {
  object_id      = "<id del objeto de Microsoft Entra>"
  principal_name = "<nombre de la entidad>"
  principal_type = "Group"
}
```

```bash
terraform -chdir=infra/azure-variantes/container-apps plan -var-file=lab.tfvars -out=base.tfplan
```

Si omites `image_digest`, el plan prepara la red, el entorno, las identidades y los servicios administrados. Revisa los recursos y su coste antes de aplicar el plan. La base aprovisiona recursos facturables incluso sin aplicaciones. Service Bus y ACR usan endpoints públicos autenticados. PostgreSQL usa acceso privado.

## Qué necesita la imagen

La imagen de `example/` es la demo de Compose con SQLite y RabbitMQ. Para activar las aplicaciones, publica primero una imagen adaptada a PostgreSQL y Azure Service Bus en el registro indicado por `registry_login_server`. Usa una identidad publicadora con permiso de escritura en el registro. La raíz asigna permiso de descarga a las identidades de ejecución.

| Configuración | Contrato de la imagen |
| --- | --- |
| `WORKLOAD_ROLE` | Arranca `api`, `publisher`, `saga`, `fulfillment` o `projection`. API y proyección escuchan en `PORT` y exponen `/healthz`. |
| `AZURE_CLIENT_ID` | Selecciona la identidad administrada del proceso para pedir los tokens de PostgreSQL y Service Bus. |
| `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGSSLMODE` | Configuran la conexión a PostgreSQL. Usa el token de Entra para autenticar la conexión y renuévalo cuando corresponda. |
| `SERVICE_BUS_FULLY_QUALIFIED_NAMESPACE`, `SERVICE_BUS_COMMANDS_QUEUE`, `SERVICE_BUS_EVENTS_TOPIC`, `SERVICE_BUS_SUBSCRIPTION` | Configuran las entidades que usa cada proceso. Envía los comandos de preparación y liberación a la cola, y los demás eventos al topic con la propiedad `eventType` y un `MessageId` estable. Las suscripciones solo se asignan a Saga y proyección. |
| `APPLICATIONINSIGHTS_CONNECTION_STRING` | Configura el destino de telemetría de una aplicación instrumentada. |

Antes de habilitar las aplicaciones, el administrador de Entra debe inicializar los esquemas y registrar los roles de PostgreSQL asociados a `workload_identities`. Usa un cliente en la red virtual que resuelva su DNS privado. En un entorno de pruebas nuevo puedes conectar un ejecutor desde una red emparejada con resolución DNS configurada o usar una máquina temporal en una tercera subred sin delegar. Esta raíz crea la red, las bases y el administrador mediante Azure Resource Manager. El ejecutor, el alta de usuarios y las migraciones requieren configuración adicional. Usa el nombre de la identidad como usuario y su `principal_id` como ID de objeto. Concede solo los permisos necesarios en la base indicada para cada proceso. [Autenticación de Entra en PostgreSQL](https://learn.microsoft.com/en-us/azure/postgresql/security/security-entra-configure)

Añade `image_repository` si usas un nombre distinto de `orders-lab` y fija `image_digest` en `lab.tfvars`. Repite el plan y revísalo antes de aplicar. API y proyección tienen ingreso interno al entorno por defecto. Ejecuta la prueba HTTP desde un cliente dentro del entorno o habilita explícitamente `public_ingress` en un sandbox. `http_urls` muestra las direcciones tras el despliegue.

Las aplicaciones usan una réplica por proceso en este taller. Mantener activos los publicadores evita que queden filas de outbox sin enviar cuando la cola de entrada está vacía. Diseña la coordinación del drenado y mide la capacidad de la base de datos antes de subir ese límite.

Esta raíz se valida sin crear recursos. La imagen adaptada y la prueba de extremo a extremo en Azure son trabajo posterior.
