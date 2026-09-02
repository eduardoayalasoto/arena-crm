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

# El builder de Railway rechaza sistemáticamente el protocolo git
# smart-http hacia github.com (12/12 intentos fallidos incluso con minutos
# de espera entre reintentos -- no es rate-limit transitorio, es un
# bloqueo/interferencia consistente), mientras que HTTPS normal sí
# funciona (la imagen base de abajo se descarga bien). Por eso frappe se
# obtiene como tarball por HTTPS en vez de "git clone", y se convierte en
# un repo git local mínimo (bench get-app / bench init lo clonan después
# desde ahí, ya sin red).
#
# pyproject.toml de frappe pinea un par de dependencias (gunicorn, PyPika)
# a un commit exacto vía "git+https://..." -- mismo protocolo bloqueado,
# así que el sed de abajo las reescribe a la URL de tarball de ese commit.
# package.json trae una más (air-datepicker, sin commit fijo -- se
# reescribe a la rama "master" de ese repo, su default branch) porque
# "bench init" ya dispara "yarn install" de frappe internamente, antes de
# que este Dockerfile llegue a instalar nada del lado Node por su cuenta.
#
# Nota sobre comentarios: Docker aplana todas las líneas continuadas con
# "\" de un RUN en una sola línea antes de pasarla al shell -- un "#" en
# medio de esa cadena "traga" como comentario todo lo que sigue en el
# resto de la línea (incluidos los "&&" restantes), así que ningún
# comentario va intercalado en el bloque de abajo; van todos aquí arriba.
RUN retry() { \
        n=1; \
        until "$@"; do \
            n=$((n + 1)); \
            if [ "$n" -gt 6 ]; then \
                echo "Fallaron 6 intentos de: $*" >&2; \
                return 1; \
            fi; \
            wait_s=$((n * 15)); \
            echo "Intento fallido, reintentando ($n/6) en ${wait_s}s: $*" >&2; \
            sleep "$wait_s"; \
        done; \
    }; \
    retry sh -c 'rm -rf /home/frappe/frappe-src && mkdir -p /home/frappe/frappe-src && curl -fsSL https://github.com/frappe/frappe/archive/refs/heads/develop.tar.gz | tar xz -C /home/frappe/frappe-src --strip-components=1' \
    && cd /home/frappe/frappe-src \
    && sed -i -E 's#git\+https://github\.com/([^@[:space:]]+)@([0-9a-f]+)#https://github.com/\1/archive/\2.tar.gz#g' pyproject.toml \
    && sed -i -E 's#git\+https://github\.com/frappe/air-datepicker#https://github.com/frappe/air-datepicker/archive/refs/heads/master.tar.gz#' package.json \
    && git init -q \
    && git add -A \
    && git -c user.email=build@localhost -c user.name=build commit -q -m "vendored from frappe/frappe develop" \
    && git branch -m develop \
    && cd /home/frappe \
    && retry sh -c 'rm -rf frappe-bench && bench init --skip-redis-config-generation --frappe-path /home/frappe/frappe-src --frappe-branch develop frappe-bench' \
    && cd frappe-bench \
    && retry sh -c 'rm -rf apps/crm && bench get-app crm /home/frappe/crm-src' \
    && retry bench setup requirements --python --node \
    && bench build --app crm \
    && sed -i '/redis/d' ./Procfile \
    && sed -i '/watch/d' ./Procfile \
    && rm -rf /home/frappe/crm-src /home/frappe/frappe-src

WORKDIR /home/frappe/frappe-bench

COPY --chown=frappe:frappe scripts/railway-entrypoint.sh ./railway-entrypoint.sh
RUN chmod +x ./railway-entrypoint.sh

EXPOSE 8000

ENTRYPOINT ["/home/frappe/frappe-bench/railway-entrypoint.sh"]
