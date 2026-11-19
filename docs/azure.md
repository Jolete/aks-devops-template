# De Kubernetes local a Azure

## Terraform en cinco minutos

Terraform lee la configuración, compara los recursos deseados con el estado y con lo que el proveedor detecta en el entorno, y calcula los cambios. El plan muestra qué va a cambiar para que puedas revisarlo. El comando `apply` ejecuta esos cambios y actualiza el estado. Por ejemplo, la referencia a ACR en la asignación de rol indica a Terraform que debe crear el registro primero.

Durante la llamada, usa el proveedor integrado de Terraform. El ejercicio escribe el estado en local y muestra un cambio propuesto. Puedes ejecutarlo sin suscripción ni acceso a la red.

```sh
cd infra/local
terraform init
terraform validate
terraform plan -out=lab.tfplan
terraform apply lab.tfplan
terraform output
terraform plan -var='environment=staging'
terraform destroy
```

El primer plan crea un recurso `terraform_data`. El segundo propone cambiar su entorno de `local` a `staging`. El recurso guarda un valor de ejemplo en el estado de Terraform. El número de réplicas es un dato del ejercicio. Los manifiestos de Kubernetes controlan las réplicas que ejecuta la demo.

## Qué cambia en AKS

| Aspecto | Local | Azure |
| --- | --- | --- |
| Imagen | Se construye con Docker y se carga en kind | Se construye una vez en CI, se publica en Azure Container Registry (ACR) y se despliega por digest |
| Kubernetes | kind ejecuta los nodos como contenedores | Azure Kubernetes Service (AKS) gestiona el plano de control. La suscripción cubre el coste de los nodos de trabajo y de otros recursos |
| Acceso al registro | kind carga la imagen directamente | La identidad administrada del kubelet descarga la imagen de ACR |
| Acceso de la aplicación | Configuración local y credenciales del taller | Microsoft Entra Workload ID permite conceder a cada aplicación acceso limitado a los recursos de Azure que necesita |
| Red | ClusterIP y reenvío local de puertos | ClusterIP para el tráfico interno. Define cómo usar Ingress o Gateway para TLS y tráfico externo |
| Configuración | Manifiestos de Kubernetes y entorno local | Reutiliza los manifiestos con valores específicos de cada entorno. Guarda los secretos en Key Vault o en el gestor de secretos elegido |
| Señales | `kubectl logs`, eventos y resultados de las sondas | Logs estructurados, métricas y trazas con Azure Monitor o con la plataforma OpenTelemetry del equipo |

Con kind puedes practicar la reconciliación de Kubernetes, la construcción de imágenes, las sondas, los despliegues y el rollback. Comprueba en AKS las identidades, los permisos del registro, la red, el almacenamiento, las cuotas y la monitorización administrada.

## Entorno de pruebas opcional en Azure

[`infra/azure`](../infra/azure/main.tf) define un grupo de recursos, un registro de nivel Basic, un clúster AKS de un nodo y una asignación de rol `AcrPull` para el kubelet. Usa Azure RBAC para el acceso al clúster y deshabilita las cuentas locales de AKS. El emisor OIDC del clúster y Workload Identity están habilitados para ejercicios posteriores. Configura por separado la identidad federada de cada aplicación que necesite acceder a Azure.

Usa una suscripción desechable o un entorno de pruebas aprobado. Por defecto, el clúster tiene un endpoint público para la API, protegido por Microsoft Entra y Azure RBAC. El nivel Free de AKS se aplica al plano de control. Los nodos, discos, la red y ACR generan costes. Antes de aplicar el plan, revisa la disponibilidad regional, la cuota de vCPU y el coste estimado. Elige un nombre de registro único a escala global. Quien aplique la configuración necesita permisos para crear recursos y asignar roles. [Precios de AKS](https://azure.microsoft.com/en-us/pricing/details/kubernetes-service/) · [Integración de AKS y ACR](https://learn.microsoft.com/en-us/azure/aks/cluster-container-registry-integration)

Durante la preparación puedes limitarte a las comprobaciones de esquema. La inicialización descarga el proveedor AzureRM y la validación se puede ejecutar sin credenciales de Azure.

```sh
cd infra/azure
terraform init -backend=false
terraform fmt -check
terraform validate
```

Para generar un plan contra el entorno de pruebas, instala Azure CLI, Terraform, kubectl y kubelogin. Ejecuta los siguientes comandos desde la raíz del repositorio. Antes de pasar de `plan` a `apply`, revisa los cambios previstos y confirma la suscripción.

```sh
cd infra/azure
az login
az account set --subscription '<sandbox-subscription-id>'
export ARM_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
export TF_VAR_name='<uniquealphanumericname>'
terraform init
terraform plan -out=azure.tfplan
terraform apply azure.tfplan
```

Para hacer un despliegue de prueba, asigna a la identidad del operador el rol **Azure Kubernetes Service Cluster User Role** y un rol de autorización de Kubernetes como **Azure Kubernetes Service RBAC Writer**, limitado al namespace de la demo. Un administrador del clúster puede crear el namespace. Concede el rol `AcrPush` sobre el registro del taller a la identidad que publica la imagen. Obtén las credenciales del clúster con `az aks get-credentials` y las salidas `resource_group` y `cluster_name` de Terraform. Si el kubeconfig usa la autenticación de Azure CLI, inicia sesión en el mismo tenant. Si necesitas convertir el kubeconfig, usa `kubelogin convert-kubeconfig -l azurecli`. Especifica el contexto de ese clúster AKS en los comandos posteriores. [Azure RBAC para Kubernetes](https://learn.microsoft.com/en-us/azure/aks/manage-azure-rbac)

Desde la raíz del repositorio, publica una imagen amd64 para el tamaño de máquina virtual que usa AKS por defecto en este taller. Ejecuta el comando que crea el namespace con una identidad de administrador del clúster. Para el despliegue, usa la identidad con permisos de escritura en ese namespace.

```sh
resource_group="$(terraform -chdir=infra/azure output -raw resource_group)"
cluster="$(terraform -chdir=infra/azure output -raw cluster_name)"
registry="$(terraform -chdir=infra/azure output -raw registry_login_server)"
image_tag="$(git rev-parse --short HEAD)-$(date +%s)"

az acr login --name "${registry%%.*}"
docker buildx build --platform linux/amd64 --push -t "$registry/devops-demo:$image_tag" .
digest="$(az acr repository show --name "${registry%%.*}" \
  --image "devops-demo:$image_tag" --query digest -o tsv)"

az aks get-credentials --resource-group "$resource_group" --name "$cluster"
kubectl --context "$cluster" apply -f k8s/00-namespace.yaml
sed "s|image: devops-demo:local|image: $registry/devops-demo@$digest|" k8s/demo.yaml \
  | kubectl --context "$cluster" apply -f -
kubectl --context "$cluster" -n devops-lab rollout status deployment/demo --timeout=120s
kubectl --context "$cluster" -n devops-lab port-forward service/demo 8080:8080
```

Desde otra terminal, ejecuta `curl -fsS http://127.0.0.1:8080/healthz`. Si la descarga de la imagen falla, revisa en los eventos del Pod el nombre de la imagen, su plataforma y si ya se han propagado los permisos. Para eliminar los recursos, revisa `terraform plan -destroy` y ejecuta `terraform destroy` desde `infra/azure` con los mismos valores de entrada y la misma suscripción.

## Antes de pasar a un entorno compartido o a producción

- **Terraform y CI/CD.** Separa el estado por entorno y usa un backend protegido en Azure Storage con autenticación de Entra, bloqueo de estado nativo y acceso limitado a las identidades de despliegue. Configura el backend primero. Genera el plan durante la revisión, aplícalo con aprobación desde un entorno protegido y despliega la imagen con el mismo digest que pasó las pruebas de staging. Usa la federación OIDC de GitHub Actions para evitar secretos persistentes en las identidades de servicio. Mantén los archivos de estado y los planes binarios fuera de Git. [Backend AzureRM](https://developer.hashicorp.com/terraform/language/backend/azurerm) · [OIDC de GitHub en Azure](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-azure)
- **Disponibilidad y escalado.** Acordad los objetivos de latencia y disponibilidad. Ejecuta pruebas de carga con tráfico representativo, compara la latencia p95, la tasa de errores, la CPU y el pico de memoria, y ajusta las solicitudes de recursos. Añade réplicas y capacidad en los nodos cuando haga falta, distribuye las réplicas entre dominios de fallo y dimensiona el presupuesto de interrupciones para permitir el mantenimiento. Para los consumidores de colas, valora escalar con KEDA según la antigüedad o la cantidad de mensajes pendientes y limita la concurrencia para proteger las bases de datos y las API.
- **Observabilidad y costes.** Empieza por la tasa de peticiones, la tasa de errores, la latencia p95 y la antigüedad de los mensajes pendientes. Propaga los identificadores de correlación entre mensajes y trazas. Genera alertas por fallos repetidos de procesamiento, mensajes en la cola de mensajes no entregados y acumulación de eventos en el outbox. Etiqueta los recursos por responsable y entorno, configura alertas de presupuesto y revisa el uso de los nodos, la ingesta de logs y su retención. Las alertas de presupuesto avisan cuando se alcanzan los umbrales. El gasto puede continuar.
- **Seguridad y recuperación.** Diseña la red y el DNS privados, limita el alcance de RBAC y Workload ID, y elige imágenes de nodo compatibles y un calendario de parches. Ensaya la restauración de datos y el rollback de la imagen. Mantén la compatibilidad del esquema con la versión anterior para que pueda ejecutarse durante el rollback. Elige los servicios de Azure según las necesidades operativas. Si la aplicación es pequeña, compara su coste recurrente con alternativas de alojamiento más sencillas. [Arquitectura de referencia de AKS](https://learn.microsoft.com/en-us/azure/architecture/reference-architectures/containers/aks/baseline-aks)
