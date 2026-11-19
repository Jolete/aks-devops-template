# Taller de DevOps para desarrolladores y arquitectos sénior

Sigue una API y su consumidor asíncrono desde la compilación local hasta el diseño de su despliegue en AKS. En cada bloque, abre los archivos del taller, explica los conceptos básicos y plantea una decisión de producción.

| Minutos | Tema | Qué mostrar |
| --- | --- | --- |
| 00–09 | Docker y Compose | Contexto de compilación, capas, configuración en ejecución y dependencias locales. |
| 09–20 | CI/CD | Alcance de cada tipo de prueba, cachés, partición de la suite y promoción por digest. |
| 20–32 | Terraform | Módulos raíz e hijos, entradas y salidas, estado y dependencias en el plan. |
| 32–48 | Kubernetes y AKS/ACR | Relacionar Compose con Kubernetes, elegir recursos y simular un despliegue fallido en kind. |
| 48–55 | Observabilidad y capacidad | Correlacionar registros, métricas y trazas. Diagnosticar una cola que envejece antes de escalar. |
| 55–60 | Saga y outbox | Seguir un pedido por RabbitMQ y mostrar una compensación o una reentrega deduplicada. |

Antes de la llamada, arranca Compose, carga la imagen en kind y ejecuta la [prueba del ejemplo de API y consumidor](ejemplo.md). Ten a mano el plan local de Terraform. El bloque de Azure es una revisión de diseño.

## Docker y CI/CD

Abre el [Dockerfile](../Dockerfile), el [archivo de Compose](../compose.yaml) y el [flujo de CI](../.github/workflows/ci.yml). El Dockerfile produce la imagen. Compose configura su ejecución, los puertos publicados y la comprobación de salud. La prueba de humo comprueba por HTTP la imagen en ejecución.

- **Caché de compilación.** Limita el contexto con `.dockerignore`. Copia los manifiestos y archivos de bloqueo de dependencias antes del código para que un cambio en el código conserve su capa. Usa compilación multietapa cuando necesites herramientas de compilación o prueba que sobran en la imagen final. Compara compilaciones en frío y con caché. En ejecutores efímeros, comprueba si transferir la caché remota de BuildKit ahorra tiempo. [Caché en Docker](https://docs.docker.com/build/cache/optimize/)
- **Caché de dependencias.** Usa el archivo de bloqueo, el sistema operativo, la arquitectura y la versión de las herramientas para formar la clave cuando corresponda. Si falta la caché, el gestor de paquetes debe poder instalar las mismas versiones. Excluye las credenciales. [Caché en GitHub Actions](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching)
- **Pruebas y partición de la suite.** Ejecuta pronto las pruebas unitarias rápidas. Usa las de integración para la base de datos, el intermediario de mensajes y las migraciones, y una prueba de humo para la imagen empaquetada. Si los tiempos lo justifican, reparte la suite en grupos sin solapamiento mediante una matriz de CI. Equilibra los grupos por duración histórica, aísla sus datos y exige que todos pasen. Compara tiempo total y minutos de ejecución antes de añadir grupos. [Matrices en GitHub Actions](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/run-job-variations)
- **Entrega.** El taller reutiliza la misma imagen en Compose y kind. En Azure, sube la imagen probada a ACR, despliégala por digest y exige que pasen el despliegue y las comprobaciones de aplicación antes de promoverla. La caché remota y la partición se tratan como decisiones de diseño para suites mayores.

## Estructura y módulos de Terraform

El módulo raíz es el directorio desde el que ejecutas Terraform. Configura los proveedores y el backend, recibe los valores del entorno y compone recursos o módulos hijos. Un módulo hijo agrupa recursos relacionados y expone entradas tipadas y salidas. El módulo organiza la configuración. El módulo raíz y su backend determinan dónde se guarda el estado. [Módulos de Terraform](https://developer.hashicorp.com/terraform/language/modules)

```text
infra/
  environments/staging/       # módulo raíz y configuración del backend
  modules/registry/           # ACR y política del registro
  modules/cluster/            # AKS, grupos de nodos e identidad del clúster
```

En cada módulo, usa `main.tf` para los recursos o llamadas a módulos, `variables.tf` para las entradas tipadas, `outputs.tf` para los valores que usan otros componentes y un README para explicar su propósito y uso. El ejemplo de Azure del taller agrupa sus recursos en un solo módulo raíz. Divídelos cuando haya una responsabilidad o configuración que convenga reutilizar. [Estructura de un módulo](https://developer.hashicorp.com/terraform/language/modules/develop/structure)

Abre el [módulo raíz de Azure](../infra/azure/main.tf). Sigue el ID de ACR y la identidad del kubelet de AKS hasta la asignación del permiso de descarga. Si extraes ACR y AKS a módulos hijos, puedes enlazar ambos en el módulo raíz mediante sus salidas. Usa el [plan local](../README.md#práctica-local-con-terraform) para explicar el estado y pregunta qué impediría aprobar un plan que reemplaza ACR o cambia la identidad del kubelet. En entornos compartidos, separa el estado por ciclo de vida y equipo responsable, usa un backend remoto con bloqueo y aplica el plan revisado.

## De Compose a Kubernetes

Abre [compose.yaml](../compose.yaml) junto al [manifiesto de Kubernetes](../k8s/demo.yaml). Compose describe cómo se ejecuta un proyecto en Docker. En Kubernetes, los controladores reconcilian continuamente el estado declarado de las cargas en el clúster.

| Concepto en Compose | Recursos y comportamiento en Kubernetes |
| --- | --- |
| API o consumidor bajo `services` | El Pod es la unidad de ejecución. Un Deployment gestiona réplicas y despliegues de cargas sin estado. |
| Nombre de servicio y publicación mediante `ports` | Un Service da a los Pods una dirección interna estable. Para enrutar HTTP externo, usa Gateway o Ingress con su controlador. |
| Variables y configuración montada | ConfigMap para configuración ordinaria y Secret para datos sensibles. ServiceAccount identifica a la carga dentro del clúster. |
| Volumen con nombre | Un PVC solicita almacenamiento persistente. Usa StatefulSet si cada réplica necesita identidad estable o almacenamiento propio. |
| Comando puntual o programado | Job ejecuta una tarea hasta completarla. CronJob programa Jobs. DaemonSet ejecuta un Pod en cada nodo elegible, por ejemplo un colector de registros. |
| Comprobación de salud y `depends_on` | La probe de readiness determina si un Pod puede recibir tráfico. La de liveness puede desencadenar el reinicio del contenedor. La de startup da margen a inicios lentos. Configura también límites de espera y reintentos ante dependencias caídas. |

Usa etiquetas y selectores para enlazar los Services con las cargas. Ajusta las solicitudes de CPU y memoria a partir de mediciones. Prueba cada probe con el tipo de fallo que pretendes detectar. En AKS, distingue la identidad del kubelet que descarga imágenes de ACR de la identidad que usa la aplicación para acceder a servicios de Azure. [Tipos de cargas en Kubernetes](https://kubernetes.io/docs/concepts/workloads/controllers/) · [Guía de AKS](azure.md)

## Simular un despliegue fallido en kind

Parte de un [despliegue local sano](../README.md#despliegue-en-kubernetes-local) en el contexto dedicado `kind-devops-lab`. Cierra el port-forward anterior antes de abrir otro para la prueba de humo.

```bash
kubectl --context kind-devops-lab -n devops-lab patch deployment/demo --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/missing"}]'
kubectl --context kind-devops-lab -n devops-lab rollout status deployment/demo --timeout=15s
kubectl --context kind-devops-lab -n devops-lab get pods -o wide
kubectl --context kind-devops-lab -n devops-lab get endpointslices \
  -l kubernetes.io/service-name=demo -o yaml
kubectl --context kind-devops-lab -n devops-lab get events --sort-by=.lastTimestamp
```

El seguimiento del despliegue agota el tiempo de espera, la probe de readiness devuelve HTTP 404 y el Pod anterior permanece listo. Compara las IP de los Pods con las direcciones de EndpointSlice y sus valores de `conditions.ready`. Haz una petición al Service desde dentro del clúster. Ambos Pods informan la misma versión de aplicación porque solo cambió la probe. El valor de readiness del EndpointSlice permite ver qué Pod puede recibir tráfico.

```bash
kubectl --context kind-devops-lab -n devops-lab exec deployment/demo -- \
  python -c 'from urllib.request import urlopen; print(urlopen("http://demo:8080/", timeout=5).read().decode())'
```

```bash
kubectl --context kind-devops-lab -n devops-lab rollout undo deployment/demo
kubectl --context kind-devops-lab -n devops-lab rollout status deployment/demo --timeout=120s
```

Vuelve a abrir el port-forward y ejecuta la prueba de humo contra la versión anterior al cambio. Pregunta qué ocurriría si una migración ya hubiera borrado una columna que esa versión necesita. Plantea añadir primero los campos nuevos, mantener compatibles los lectores y formatos de mensajes durante el despliegue y retirar los campos antiguos cuando ya no queden versiones ni mensajes que los necesiten.

## Observar y dimensionar el sistema

Usa registros estructurados para investigar una petición, métricas para detectar cambios en el sistema y trazas para seguir una operación entre API, consumidor e intermediario de mensajes. En el taller, busca el mismo `saga_id` en la respuesta HTTP y los registros. En producción, propaga el contexto de traza en los mensajes y evita usar identificadores únicos como etiquetas de métricas. Empieza por la tasa de peticiones, los errores, la latencia p95 y la antigüedad del mensaje más viejo.

Si la cola envejece con CPU baja, compara la tasa de entrada y procesamiento, el volumen de reintentos y la latencia de la base de datos. Escala los consumidores si su capacidad limita el caudal y la base de datos tiene margen. Comprueba el efecto siguiendo a la vez la antigüedad de la cola y la latencia de las dependencias.

## Cierre con Saga y outbox

Abre la [práctica de pedidos y colas](ejemplo.md) y sigue un pedido desde la escritura inicial hasta la proyección. Durante la sesión, usa el caso de rechazo para mostrar el comando de compensación. Ejecuta el resto de los escenarios durante la preparación.

- **Fallo antes de completar el procesamiento.** Compara la cola de reintentos con la de mensajes fallidos. Pregunta qué alerta se activa si el evento más antiguo supera el objetivo de entrega.
- **El intermediario acepta el evento y el publicador cae antes de registrar el éxito.** El evento puede enviarse de nuevo. Pregunta dónde guarda el consumidor la marca de deduplicación y si la confirma en la misma transacción que el efecto de negocio.
- **Una acción posterior se rechaza de forma permanente.** Decide quién puede poner el evento en cuarentena y reenviarlo, cuándo corresponde compensar y cómo reintentar la compensación de forma segura. Liberar la reserva compensa un efecto de negocio. Restaurar una revisión de Kubernetes recupera la configuración del despliegue.
