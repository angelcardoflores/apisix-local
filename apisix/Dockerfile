FROM apache/apisix:3.16.0-debian
USER root
RUN apt-get update && apt-get install -y curl && rm -rf /var/lib/apt/lists/*
# El file-logger escribe desde los workers (nginx los corre como 'nobody', uid 65534).
# En vez de abrir el dir a todos (777), se lo damos en propiedad a ese usuario con 755:
# el worker escribe (es el dueño) y el dir NO queda world/group-writable (logrotate
# no necesita 'su'). Un volumen nuevo hereda dueño y permisos al crearse.
RUN mkdir -p /usr/local/apisix/logs \
    && chown 65534:65534 /usr/local/apisix/logs \
    && chmod 755 /usr/local/apisix/logs