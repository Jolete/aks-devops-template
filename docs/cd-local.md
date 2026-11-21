# Entrega continua a k3s local

El flujo de GitHub Actions despliega la demo pequeña del taller en un clúster k3d dedicado. El runner y Docker se ejecutan en el mismo equipo. GitHub pone el trabajo en cola y el runner inicia la conexión de salida. La API de Kubernetes permanece en el equipo local.

## 1. Preparar el equipo

En **Windows**, instala Ubuntu en WSL 2 e integra esa distribución con Docker Desktop en modo contenedores Linux. Usa Bash dentro de Ubuntu para k3d, kubectl y el runner. En el formulario de GitHub elige **Linux** con la arquitectura de Ubuntu.

En **macOS**, usa Terminal con Docker Desktop en marcha. Elige **macOS** y la arquitectura del Mac en el formulario del runner.

Comprueba desde la cuenta que ejecutará el runner:

```bash
uname -m
git --version
docker version
k3d version
kubectl version --client
python3 --version
curl --version
```

## 2. Crear el clúster de entrega

Usa un clúster distinto del ejercicio de Terraform. El workflow administra los recursos de la demo en este clúster.

```bash
k3d cluster create devops-cd --api-port 127.0.0.1:16443 \
  --kubeconfig-update-default=false --kubeconfig-switch-context=false
```

Desde la misma terminal que usará el runner, comprueba tanto el acceso a Docker como la conexión a Kubernetes. El kubeconfig temporal contiene acceso administrativo al clúster de prácticas. [Cómo gestiona k3d los kubeconfigs](https://k3d.io/stable/usage/kubeconfig/)

```bash
k3d cluster list
runner_kubeconfig="$(mktemp)"
k3d kubeconfig get devops-cd > "$runner_kubeconfig"
kubectl --kubeconfig "$runner_kubeconfig" --context k3d-devops-cd get --raw=/readyz
unlink "$runner_kubeconfig"
```

Espera la respuesta `ok` antes de registrar el runner. Si en WSL funciona Docker pero falla el acceso a `127.0.0.1:16443`, revisa la integración de Docker Desktop con tu distribución y si puedes usar el modo de red reflejada. [Redes en WSL](https://learn.microsoft.com/windows/wsl/networking)

## 3. Registrar el runner del repositorio

1. Usa un repositorio **privado** y un usuario o máquina de laboratorio dedicado. Quien pueda cambiar los workflows puede ejecutar código con los permisos de esa cuenta. El acceso a Docker también permite controlar sus contenedores y volúmenes. Mantén fuera de esa cuenta las credenciales y contextos de producción. [Seguridad de GitHub Actions](https://docs.github.com/en/actions/reference/security/secure-use)
2. En GitHub, abre **Settings → Actions → Runners → New self-hosted runner**. Copia los comandos de descarga y extracción correspondientes al sistema y arquitectura. Instala el runner fuera del checkout, por ejemplo en `~/actions-runner-k3s`.
3. Ejecuta el comando `./config.sh` que muestra GitHub y añádele `--name devops-cd --labels k3s-lab`. Usa el token temporal que genera GitHub directamente en la terminal. Evita pegarlo en un chat o guardarlo en el repo.
4. Ejecuta `./run.sh` en primer plano en esa misma terminal. GitHub debe mostrar el runner como **Idle**. En WSL, mantén la distribución abierta y Docker Desktop en marcha durante el ejercicio. [Instalación oficial de runners](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/add-runners)

## 4. Desplegar y comprobar

Publica el workflow en la rama principal. En **Actions**, comprueba que la CI del commit de `main` pasó. Abre **Deploy the local k3s lab → Run workflow**, selecciona `main` y lanza la entrega. El primer job comprueba que ese mismo SHA pasó la CI de un push a `main` antes de enviar el trabajo al runner del laboratorio.

El runner construye o reutiliza la imagen etiquetada con el SHA del commit, la importa en k3d, espera al rollout y ejecuta la prueba de humo. Los despliegues a ese clúster se serializan. Revisa en el job el commit desplegado y los resultados de confirmación y compensación. Si una actualización falla, el script intenta restaurar y comprobar la revisión anterior. La ejecución queda marcada como fallida para que puedas investigarla.

Para probar el paso de despliegue desde el checkout local antes de registrar el runner, ejecuta `./scripts/deploy-k3s.sh` desde la raíz en un árbol limpio. Esa prueba local utiliza el clúster dedicado y prescinde de la comprobación de CI que realiza GitHub.

Si queda en cola, comprueba que el runner figura conectado y tiene la etiqueta `k3s-lab`. Si el job no encuentra Docker o k3d, verifica la ruta de herramientas desde la terminal que inició `./run.sh`. Si no encuentra el clúster, comprueba que el runner y k3d usan el mismo motor Docker. Al acabar, detén el runner con Ctrl+C. Para retirar el registro, usa el comando de eliminación que ofrece GitHub en la página de ese runner.

## Prompt para pedir ayuda a una IA

```text
Ayúdame a ejecutar el CD del repositorio DevOps que tengo abierto. Primero lee
.github/workflows/cd-local.yml, scripts/deploy-k3s.sh y docs/cd-local.md.
Adapta los pasos a mi sistema: Windows con Ubuntu en WSL 2 o macOS.
Comprueba Git, Docker, k3d, kubectl, Python 3 y curl desde la cuenta del runner.
El destino es el clúster local dedicado devops-cd, contexto k3d-devops-cd,
namespace devops-lab. No cambies el contexto global ni uses clústeres externos.
Guíame para registrar en un repositorio privado un runner con etiqueta k3s-lab.
Indícame en qué pantalla obtener los comandos de registro. Pídeme que introduzca
el token directamente en mi terminal; no me pidas que te envíe tokens ni kubeconfigs.
Después, comprueba la CI del commit de main y guíame para ejecutar el workflow
manual, verificar el rollout y explicar los resultados de la prueba de humo.
Si falla un paso, inspecciona el estado y explica qué indica antes de cambiar nada.
No borres clústeres ni cambies configuración de GitHub sin que te lo pida.
```
