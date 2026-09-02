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

# Git no debe intentar pedir credenciales interactivamente -- si una
# conexión falla a media negociación (ver más abajo), que git falle
# rápido y limpio en vez de bloquearse esperando un prompt que nunca
# llegará (no hay terminal en el build).
ENV GIT_TERMINAL_PROMPT=0

# Los pasos de abajo clonan varios repos git (frappe, sus dependencias con
# pin a commit exacto como gunicorn, etc.) -- el builder remoto de Railway
# choca seguido con el rate-limit anónimo de GitHub para git smart-http
# (probablemente por compartir salida de red con muchos otros builds), así
# que cada paso que depende de red se reintenta con backoff creciente.
# Cada intento arranca de cero (rm -rf antes de reintentar): un intento
# fallido deja el directorio a medias, y reusarlo (p.ej. "bench init
# --ignore-exist" sobre un Procfile ya creado) dispara un prompt
# interactivo de bench que aborta solo en un build sin terminal.
RUN retry() { \
        n=1; \
        until "$@"; do \
            n=$((n + 1)); \
            if [ "$n" -gt 6 ]; then \
                echo "Fallaron 6 intentos de: $*" >&2; \
                return 1; \
            fi; \
            wait_s=$((n * 20)); \
            echo "Intento fallido, reintentando ($n/6) en ${wait_s}s: $*" >&2; \
            sleep "$wait_s"; \
        done; \
    }; \
    # Frappe se clona una sola vez a una ruta local: "bench init" valida la
    # rama con "git ls-remote" contra el path que le demos, así que
    # pasándole un checkout ya local (--frappe-path) evita que vuelva a
    # pegarle a GitHub por red -- solo el clone de abajo lo hace, y ese sí
    # está cubierto por el retry.
    retry sh -c 'rm -rf /home/frappe/frappe-src && git clone --depth 1 --branch develop https://github.com/frappe/frappe.git /home/frappe/frappe-src' \
    && retry sh -c 'rm -rf frappe-bench && bench init --skip-redis-config-generation --frappe-path /home/frappe/frappe-src --frappe-branch develop frappe-bench' \
    && cd frappe-bench \
    && retry sh -c 'rm -rf apps/crm && bench get-app crm /home/frappe/crm-src' \
    && retry bench setup requirements --python --node \
    && bench build --app crm \
    # Redis y el auto-rebuild de assets ("watch") los maneja Railway/no aplican
    # en producción -- se quitan del Procfile igual que en docker/init.sh.
    && sed -i '/redis/d' ./Procfile \
    && sed -i '/watch/d' ./Procfile \
    && rm -rf /home/frappe/crm-src /home/frappe/frappe-src

WORKDIR /home/frappe/frappe-bench

COPY --chown=frappe:frappe scripts/railway-entrypoint.sh ./railway-entrypoint.sh
RUN chmod +x ./railway-entrypoint.sh

EXPOSE 8000

ENTRYPOINT ["/home/frappe/frappe-bench/railway-entrypoint.sh"]
