# Imagen "todo en uno" para desplegar este fork de Frappe CRM en Railway:
# un solo contenedor con backend (gunicorn), websocket, workers y scheduler,
# corridos juntos vía `bench start` (igual que en desarrollo).
#
# Reutiliza el mismo toolchain e imagen base que ya usan docker/init.sh y
# .devcontainer/ para desarrollo local (frappe/bench:latest trae Python,
# Node, yarn, wkhtmltopdf, mariadb-client y redis-tools preinstalados),
# y el mismo flujo de "bench init" + "bench get-app" -- solo que aquí
# "bench get-app" apunta al código de este repo (ya copiado a la imagen)
# en vez de clonarlo desde GitHub.
#
# Ver RAILWAY.md para las variables de entorno y los servicios (MariaDB,
# Redis) que hay que crear en Railway antes de desplegar esta imagen.

FROM frappe/bench:latest

USER frappe
WORKDIR /home/frappe

# Código de este repo == la app "crm". Se copia aparte de frappe-bench para
# que "bench get-app" lo registre igual que haría con un git remoto.
COPY --chown=frappe:frappe . /home/frappe/crm-src

RUN bench init \
        --skip-redis-config-generation \
        --frappe-branch develop \
        frappe-bench \
    && cd frappe-bench \
    && bench get-app crm /home/frappe/crm-src \
    && bench setup requirements --python --node \
    && bench build --app crm \
    # Redis y el auto-rebuild de assets ("watch") los maneja Railway/no aplican
    # en producción -- se quitan del Procfile igual que en docker/init.sh.
    && sed -i '/redis/d' ./Procfile \
    && sed -i '/watch/d' ./Procfile \
    && rm -rf /home/frappe/crm-src

WORKDIR /home/frappe/frappe-bench

COPY --chown=frappe:frappe scripts/railway-entrypoint.sh ./railway-entrypoint.sh
RUN chmod +x ./railway-entrypoint.sh

EXPOSE 8000

ENTRYPOINT ["/home/frappe/frappe-bench/railway-entrypoint.sh"]
