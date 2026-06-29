FROM apache/apisix:3.16.0-debian
USER root
RUN apt-get update && apt-get install -y curl && rm -rf /var/lib/apt/lists/*
# NOTA: la imagen oficial monta /usr/local/apisix/logs como VOLUME world-writable
# (777, dueño 636), así que cualquier chown/chmod aqui se DESCARTA. El worker (nobody)
# puede escribir gracias a ese 777; la rotacion lo maneja con 'su root root' en logrotate.