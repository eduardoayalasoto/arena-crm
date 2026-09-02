# Imagen "todo en uno" para desplegar este fork de Frappe CRM en Railway:
# un solo contenedor con backend (gunicorn), websocket, workers y scheduler,
# corridos juntos vía `bench start` (igual que en desarrollo).
#
# Reutiliza el mismo toolchain e imagen base que ya usan docker/init.sh y
# .devcontainer/ para desarrollo local (frappe/bench:latest trae Python,
# Node, yarn, wkhtmltopdf, mariadb-client y redis-tools preinstalados).
#
# Ver RAILWAY.md para las variables de entorno y los servicios (MariaDB,
# Redis) que hay que crear en Railway antes de desplegar esta imagen.
#
# --- Notas de depuración que explican por qué el Dockerfile se ve así ---
#
# 1) Railway genera su propio snapshot del código antes de pasarlo al
#    build de Docker ("unpacking archive" / "uploading snapshot" en sus
#    logs) y ese snapshot NO incluye ".git", pase lo que pase en
#    .dockerignore. Por eso este Dockerfile no usa "bench get-app" (que
#    asume un repo git real) ni "git clone" del código de este repo -- el
#    código se copia directo a apps/crm con COPY normal, y sus deps se
#    instalan a mano (pip install -e / yarn install), sin pasar por bench
#    para "adoptar" la app.
#
# 2) El framework Frappe en sí SÍ se obtiene por HTTPS -- pero no con
#    "git clone": el builder de Railway rechaza sistemáticamente el
#    protocolo git smart-http hacia github.com (confirmado con 12/12
#    intentos fallidos, con hasta 2 minutos de espera entre reintentos --
#    no es rate-limit transitorio), mientras que HTTPS normal sí funciona
#    (la imagen base de abajo se descarga bien, igual que los tarballs de
#    más adelante). Por eso frappe se obtiene como tarball (curl | tar) y
#    se convierte en un repo git local mínimo para que "bench init" lo
#    use sin volver a tocar la red.
#
# 3) pyproject.toml de frappe pinea un par de dependencias (gunicorn,
#    PyPika) a un commit exacto vía "git+https://..." -- mismo protocolo
#    bloqueado, así que un sed las reescribe a la URL de tarball de ese
#    commit. package.json trae una más (air-datepicker, sin commit fijo
#    -- se reescribe a la rama "master" de ese repo) porque "bench init"
#    ya dispara "yarn install" de frappe internamente.
#
# 4) Nota sobre comentarios: Docker aplana todas las líneas continuadas
#    con "\" de un RUN en una sola línea antes de pasarla al shell -- un
#    "#" en medio de esa cadena "traga" como comentario todo lo que sigue
#    en el resto de la línea (incluidos los "&&" restantes), así que
#    ningún comentario va intercalado en los bloques RUN de abajo.
#
# 5) sites/apps.txt (registro de apps a nivel bench) se actualiza con
#    "printf '\ncrm\n' >>", no "echo crm >>": bench init deja ese archivo
#    sin salto de línea final, así que un simple "echo crm >>" concatena
#    directo al final de la línea existente ("frappe" + "crm" =
#    "frappecrm", una sola línea) en vez de agregar una línea nueva --
#    Frappe entonces busca un módulo Python "frappecrm" que no existe. El
#    "\n" inicial del printf garantiza una línea nueva pase lo que pase
#    (una línea en blanco de más al inicio no afecta -- frappe.utils.
#    get_file_items la ignora).

FROM frappe/bench:latest

USER frappe
WORKDIR /home/frappe

ENV GIT_TERMINAL_PROMPT=0

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
    && rm -rf /home/frappe/frappe-src

# Código de este repo == la app "crm", copiado directo a su ubicación
# final dentro del bench (sin pasar por git ni por "bench get-app": ver
# nota 1 arriba).
COPY --chown=frappe:frappe . /home/frappe/frappe-bench/apps/crm

WORKDIR /home/frappe/frappe-bench

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
    printf '\ncrm\n' >> sites/apps.txt \
    && retry env/bin/python -m pip install --quiet -e apps/crm \
    && retry sh -c 'cd apps/crm/frontend && yarn install --check-files' \
    && bench build --app crm \
    && sed -i '/redis/d' ./Procfile \
    && sed -i '/watch/d' ./Procfile

COPY --chown=frappe:frappe scripts/railway-entrypoint.sh ./railway-entrypoint.sh
RUN chmod +x ./railway-entrypoint.sh

EXPOSE 8000

ENTRYPOINT ["/home/frappe/frappe-bench/railway-entrypoint.sh"]
