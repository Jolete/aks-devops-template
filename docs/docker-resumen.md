# Docker en el taller

Una imagen empaqueta el código y sus dependencias. Un contenedor ejecuta esa imagen con su propia configuración. Compose describe cómo arrancar varios contenedores y conectar sus redes y volúmenes. En el [ejemplo de pedidos](ejemplo.md), API y publicador comparten el volumen de pedidos. RabbitMQ y los demás procesos conservan su estado en volúmenes propios. [Docker Compose](https://docs.docker.com/compose/)

## Caché y etapas de construcción

- Copia primero el manifiesto de dependencias, instálalas y después copia el código. El [Dockerfile de pedidos](../example/Dockerfile) usa ese orden. Al cambiar solo un archivo Python, BuildKit puede reutilizar la capa de instalación. Si cambia `requirements.txt`, se repite la instalación. [Caché de construcción](https://docs.docker.com/build/cache/optimize/)
- Reduce lo que llega al constructor con `.dockerignore`. El [archivo de la demo](../.dockerignore) restringe el contexto al único archivo Python que necesita ese Dockerfile. Cada contexto debe excluir sus propios archivos innecesarios. [Contexto de construcción](https://docs.docker.com/build/concepts/context/)
- Usa varias etapas cuando necesites SDK, compiladores o dependencias de prueba. Compila en una primera etapa y pasa los artefactos necesarios al entorno de ejecución con `COPY --from=build`. El [Dockerfile de la demo](../Dockerfile) tiene una etapa porque ejecuta un solo archivo con el intérprete de la imagen base. [Construcción multietapa](https://docs.docker.com/build/building/multi-stage/)

Desde la raíz, ejecuta dos veces el mismo comando. En la segunda ejecución, la salida muestra qué pasos se reutilizaron. `docker image ls` muestra el tamaño local de la imagen. [Inspección de imágenes](https://docs.docker.com/reference/cli/docker/image/ls/)

```bash
docker build --progress=plain -t devops-orders:local example/
docker build --progress=plain -t devops-orders:local example/
docker image ls devops-orders:local
```

## Imágenes pequeñas y contenedores con permisos mínimos

- Parte de una imagen base mantenida, instala solo lo necesario y fija las dependencias. Para reproducir el despliegue, publica la imagen probada y promueve su digest. Actualiza el digest de la base mediante cambios revisados para incorporar parches. [Buenas prácticas de Dockerfile](https://docs.docker.com/build/building/best-practices/)
- Ejecuta con un usuario sin privilegios. Ambas imágenes del taller usan el UID 10001. Monta los datos donde la aplicación necesita escribir, como `/data` en pedidos. Para procesos que admitan raíz de solo lectura, actívala y elimina las capacidades innecesarias. [Opciones de seguridad de Docker](https://docs.docker.com/engine/containers/run/)
- Inyecta las credenciales de ejecución al arrancar el contenedor. Si una instalación necesita un secreto durante la construcción, usa `--secret` con `RUN --mount=type=secret`. Los argumentos de construcción y las variables del Dockerfile pueden quedar registrados en la imagen o sus metadatos. [Secretos de construcción](https://docs.docker.com/build/building/secrets/)
