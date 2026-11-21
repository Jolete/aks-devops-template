# K3s en el taller

K3s empaqueta Kubernetes con componentes como containerd y metrics-server. K3d ejecuta nodos K3s en contenedores Docker para el laboratorio. El manifiesto de la demo sirve en kind y K3s. En la [práctica de Terraform](k3s.md), k3d crea el clúster y Terraform aplica los recursos con un contexto aislado. [Componentes de K3s](https://docs.k3s.io/installation/packaged-components) · [K3d](https://k3d.io/stable/)

## Recursos de la demo

| Recurso | Función en el laboratorio |
| --- | --- |
| Namespace `devops-lab` | Agrupa los objetos de la práctica. |
| Deployment `demo` | Mantiene las réplicas declaradas y crea Pods a partir de su plantilla. |
| Pod | Ejecuta el contenedor. La sonda de readiness lo habilita para recibir tráfico. La de liveness permite reiniciar un contenedor que deja de responder. |
| Service `demo` | Mantiene una dirección interna estable y selecciona los Pods con la etiqueta `app=demo`. |
| ConfigMap, Secret y PVC | Usaría estos recursos para separar la configuración, las credenciales y el almacenamiento persistente al trasladar el ejemplo distribuido. |

[Manifiesto de la demo](../k8s/demo.yaml) · [Sondas de Kubernetes](https://kubernetes.io/docs/concepts/configuration/liveness-readiness-startup-probes/)

Con el clúster de la práctica en marcha, conserva la variable `lab_kubeconfig` y ejecuta estos comandos para inspeccionarlo.

```bash
kubectl --kubeconfig "$lab_kubeconfig" --context k3d-devops-tf-lab \
  -n devops-lab get deployment,pod,service
kubectl --kubeconfig "$lab_kubeconfig" --context k3d-devops-tf-lab \
  -n devops-lab describe deployment demo
kubectl --kubeconfig "$lab_kubeconfig" --context k3d-devops-tf-lab \
  -n devops-lab logs -l app=demo --prefix
```

## Requests, límites y HPA

El scheduler usa los `requests` de CPU y memoria para colocar los Pods. Los límites restringen el consumo. Llegar al límite de CPU puede provocar throttling; rebasar el límite de memoria puede provocar un `OOMKilled`. La demo pide `25m` de CPU y fija un límite de `250m`. Usa esos valores para el ejercicio y mide latencia, errores y consumo antes de dimensionar otra carga. [Recursos de Kubernetes](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/)

Un HPA ajusta el número de réplicas dentro de un rango. Para escalar por utilización de CPU, el clúster necesita la API de métricas y el Deployment debe declarar un request de CPU. Comprueba que `kubectl top pods` devuelve datos en el contexto correcto. Este ejemplo apunta al Deployment del taller. Puedes guardarlo como `hpa.yaml` y aplicarlo en el clúster de práctica si quieres ensayar el escalado. [Horizontal Pod Autoscaling](https://kubernetes.io/docs/concepts/workloads/autoscaling/horizontal-pod-autoscale/)

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: demo
  namespace: devops-lab
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: demo
  minReplicas: 1
  maxReplicas: 3
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 60
```

El 60 % equivale a una media de `15m` por Pod con el request de la demo. Si dejas el HPA activo, dale el control del número de réplicas y retira `spec.replicas` del manifiesto gestionado. Para un consumidor de mensajes, mide la antigüedad y la profundidad de la cola y valida la capacidad de la base de datos antes de subir la concurrencia. [Métricas del HPA](https://kubernetes.io/docs/concepts/workloads/autoscaling/horizontal-pod-autoscale/)

El HPA escala Pods dentro de la capacidad disponible. Ajusta los nodos del clúster de k3d por separado. Si el HPA pide réplicas y quedan en `Pending`, inspecciona los eventos de planificación para comprobar si faltan recursos.

En el taller, usa el contexto de laboratorio y conserva el Service como acceso interno. Revisa los logs y los eventos si el rollout se atasca. En un entorno compartido, aplica RBAC de mínimo privilegio, separa las credenciales de los manifiestos y define cómo recuperar los volúmenes y el datastore del clúster. [RBAC](https://kubernetes.io/docs/reference/access-authn-authz/rbac/) · [Copias de seguridad de K3s](https://docs.k3s.io/datastore/backup-restore)
