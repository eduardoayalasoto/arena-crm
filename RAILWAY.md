# Desplegar este fork en Railway

Arquitectura "todo en uno": un solo servicio Railway (este repo, build vía
`Dockerfile`) corriendo backend + websocket + workers + scheduler juntos
(`bench start`), más dos servicios de datos. Pensada para validar que el
código funciona, no para producción real (ver "Limitaciones" al final).

## 1. Servicios a crear en el proyecto de Railway

### a) MariaDB
Frappe requiere **MariaDB**, no el addon nativo "MySQL" de Railway (no hay
garantía de compatibilidad total con MySQL puro). Crear un servicio nuevo:

- **New → Docker Image** → `mariadb:10.8`
- Variable: `MARIADB_ROOT_PASSWORD` = (elige una contraseña) -- esta versión de
  la imagen oficial ya no acepta `MYSQL_ROOT_PASSWORD`, exige el nombre
  `MARIADB_*` (confirmado por el propio entrypoint de la imagen al fallar
  sin él)
- Agregar un **Volume** montado en `/var/lib/mysql` (si no, se pierde la
  base de datos en cada redeploy)

### b) Redis
- **New → Database → Add Redis** (el addon nativo de Railway sirve bien aquí)

### c) Este repo (servicio "crm")
- **New → GitHub Repo** → selecciona este repositorio/rama
- Railway detecta `Dockerfile` y `railway.json` automáticamente
- Agregar un **Volume** montado en `/home/frappe/frappe-bench/sites`
  (persiste el sitio entre despliegues -- sin esto, cada redeploy recrea
  el sitio desde cero)
- Generar un dominio público (Settings → Networking → Generate Domain)

## 2. Variables de entorno del servicio "crm"

| Variable            | Valor                                                         |
|----------------------|---------------------------------------------------------------|
| `DB_HOST`            | `${{MariaDB.RAILWAY_PRIVATE_DOMAIN}}` (nombre del servicio MariaDB) |
| `DB_ROOT_PASSWORD`   | `${{MariaDB.MARIADB_ROOT_PASSWORD}}`                           |
| `REDIS_CACHE_URL`    | `${{Redis.REDIS_URL}}`                                         |
| `REDIS_QUEUE_URL`    | `${{Redis.REDIS_URL}}`                                         |
| `ADMIN_PASSWORD`     | contraseña del usuario Administrator del sitio                |
| `SITE_NAME`          | opcional, default `crm.local`                                 |

`PORT` y `RAILWAY_PUBLIC_DOMAIN` los inyecta Railway automáticamente, no
hace falta declararlos.

Usa las [variable references](https://docs.railway.com/guides/variables#reference-variables)
de Railway (`${{Servicio.VARIABLE}}`) para no copiar contraseñas a mano
entre servicios.

## 3. Primer despliegue

El build tarda bastante (clona el framework Frappe, instala dependencias
Python/Node y compila los assets del frontend) -- espera varios minutos en
el primer deploy. El arranque del contenedor (`scripts/railway-entrypoint.sh`)
crea el sitio automáticamente la primera vez; en los redeploys siguientes
solo migra.

## 4. Limitaciones de este setup ("todo en uno")

- `bench start` usa el servidor de desarrollo de Werkzeug para el proceso
  web, no gunicorn -- adecuado para validar el código, no para tráfico de
  producción real.
- El proceso de websocket (Socket.IO, puerto 9000) queda interno, no
  expuesto en el dominio público de Railway -- funcionalidades en tiempo
  real (notificaciones live) no llegarán al navegador a través del dominio
  público sin exponer ese puerto aparte.
- Un único contenedor concentra backend, workers y scheduler: si un worker
  se cuelga, se lleva el proceso web con el reinicio del contenedor.

Si más adelante se necesita algo más cercano a producción real, el patrón
oficial de Frappe (`frappe/frappe_docker`) separa esto en servicios
independientes (backend con gunicorn, websocket, workers de cola corta y
larga, scheduler) -- vale la pena migrar a eso antes de exponer esto a
usuarios reales.
