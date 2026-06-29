FROM alpine:3.20
RUN apk add --no-cache logrotate && mkdir -p /var/lib/logrotate
# La config se COPIA (no se monta) para que sea root:root 644 y logrotate no la
# rechace por permisos. Si cambias la política de rotación, reconstruye este sidecar.
COPY apisix-logs.conf /etc/logrotate.d/apisix-logs
# logrotate exige que la config no sea "writable by others"; el COPY desde Windows
# la deja en 0755, así que la fijamos a 0644 root:root.
RUN chmod 0644 /etc/logrotate.d/apisix-logs
