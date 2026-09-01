#!/bin/bash
# Entrypoint del contenedor "todo en uno" para Railway.
#
# En cada arranque:
#   1. Apunta el bench a los servicios externos de MariaDB y Redis de Railway.
#   2. Crea el sitio la primera vez (o lo migra si ya existe -- persistido en
#      un Volume de Railway montado en sites/, ver RAILWAY.md).
#   3. Levanta backend + websocket + workers + scheduler con `bench start`.
#
# Variables de entorno requeridas -- ver RAILWAY.md para cómo mapearlas
# a los servicios de Railway:
#   DB_HOST, DB_PORT, DB_ROOT_PASSWORD
#   REDIS_CACHE_URL, REDIS_QUEUE_URL, REDIS_SOCKETIO_URL
#   ADMIN_PASSWORD
# Opcionales:
#   SITE_NAME (default: crm.local)
#   PORT (Railway la inyecta sola)
#   RAILWAY_PUBLIC_DOMAIN (Railway la inyecta sola si el servicio tiene dominio)

set -euo pipefail

cd /home/frappe/frappe-bench

: "${DB_HOST:?Falta la variable de entorno DB_HOST (host de MariaDB)}"
: "${DB_PORT:=3306}"
: "${DB_ROOT_PASSWORD:?Falta la variable de entorno DB_ROOT_PASSWORD}"
: "${ADMIN_PASSWORD:?Falta la variable de entorno ADMIN_PASSWORD}"
: "${REDIS_CACHE_URL:?Falta la variable de entorno REDIS_CACHE_URL}"
: "${REDIS_QUEUE_URL:?Falta la variable de entorno REDIS_QUEUE_URL}"
: "${REDIS_SOCKETIO_URL:=$REDIS_QUEUE_URL}"
: "${SITE_NAME:=crm.local}"
: "${PORT:=8000}"

echo "==> Configurando hosts de MariaDB y Redis"
bench set-mariadb-host "$DB_HOST"
bench set-config -g db_port "$DB_PORT"
bench set-redis-cache-host "$REDIS_CACHE_URL"
bench set-redis-queue-host "$REDIS_QUEUE_URL"
bench set-redis-socketio-host "$REDIS_SOCKETIO_URL"
bench set-config -g webserver_port "$PORT"

echo "==> Esperando a MariaDB en $DB_HOST:$DB_PORT"
for i in $(seq 1 60); do
    if mysqladmin ping -h "$DB_HOST" -P "$DB_PORT" -u root -p"$DB_ROOT_PASSWORD" --silent 2>/dev/null; then
        echo "MariaDB disponible."
        break
    fi
    echo "  intento $i/60, reintentando en 2s..."
    sleep 2
done

if [ ! -d "sites/$SITE_NAME" ]; then
    echo "==> Sitio $SITE_NAME no existe, creándolo (bench new-site + install-app crm)"
    bench new-site "$SITE_NAME" \
        --mariadb-root-password "$DB_ROOT_PASSWORD" \
        --admin-password "$ADMIN_PASSWORD" \
        --install-app crm \
        --no-mariadb-socket \
        --db-host "$DB_HOST" \
        --db-port "$DB_PORT"
else
    echo "==> Sitio $SITE_NAME ya existe, migrando"
    bench --site "$SITE_NAME" migrate
fi

bench use "$SITE_NAME"

if [ -n "${RAILWAY_PUBLIC_DOMAIN:-}" ]; then
    bench --site "$SITE_NAME" set-config host_name "https://$RAILWAY_PUBLIC_DOMAIN"
fi

bench --site "$SITE_NAME" set-config developer_mode 0
bench --site "$SITE_NAME" set-config mute_emails "${MUTE_EMAILS:-1}"
bench --site "$SITE_NAME" clear-cache

echo "==> Levantando backend + websocket + workers + scheduler"
exec bench start
