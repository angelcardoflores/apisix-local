FROM apache/apisix:3.16.0-debian
USER root
RUN apt-get update && apt-get install -y curl && rm -rf /var/lib/apt/lists/*
# El file-logger escribe desde los workers (usuario no-root). Garantizamos que el
# directorio de logs sea escribible; un volumen nuevo hereda estos permisos al crearse.
RUN mkdir -p /usr/local/apisix/logs && chmod 777 /usr/local/apisix/logs