# Terraform con k3s en Windows y macOS

En Windows, ejecuta los bloques en Ubuntu bajo WSL 2 con la integración de Docker Desktop activada. En macOS, usa Terminal con Docker Desktop en marcha. Instala [k3d](https://k3d.io/stable/), Terraform y kubectl en esa misma terminal.

El ejercicio crea un k3s local con k3d y usa Terraform para gestionar el namespace, el Deployment y el Service de la demo sintética. Reutiliza los manifiestos de kind. Ejecuta los comandos desde la raíz del repositorio y conserva la terminal para reutilizar las variables.

```bash
k3d cluster create devops-tf-lab \
  --kubeconfig-update-default=false --kubeconfig-switch-context=false
lab_kubeconfig="$(mktemp)"
k3d kubeconfig get devops-tf-lab > "$lab_kubeconfig"
export TF_VAR_kubeconfig_path="$lab_kubeconfig"
export TF_VAR_kube_context=k3d-devops-tf-lab

docker build -t devops-demo:local .
k3d image import devops-demo:local --cluster devops-tf-lab

terraform -chdir=infra/k3s init
terraform -chdir=infra/k3s plan -out=lab.tfplan
terraform -chdir=infra/k3s apply lab.tfplan
kubectl --kubeconfig "$lab_kubeconfig" --context k3d-devops-tf-lab \
  -n devops-lab rollout status deployment/demo --timeout=120s
kubectl --kubeconfig "$lab_kubeconfig" --context k3d-devops-tf-lab \
  -n devops-lab port-forward service/demo 18081:8080
```

En otra terminal del mismo entorno, ejecuta `./scripts/smoke.sh http://127.0.0.1:18081 local`. Verás los casos de confirmación y compensación. Detén el port-forward y destruye primero los recursos para que Terraform siga teniendo acceso al clúster.

```bash
terraform -chdir=infra/k3s destroy &&
  k3d cluster delete devops-tf-lab &&
  unlink "$lab_kubeconfig"
```

Esta práctica usa la demo sintética de Saga. El [ejemplo de pedidos con RabbitMQ](ejemplo.md) se ejecuta con Compose y permite explorar colas, persistencia y reintentos. Para llevar esa pila a Kubernetes, define el almacenamiento del intermediario y de cada servicio, el acceso a las credenciales y el ciclo de vida de la identidad de cada carga.
