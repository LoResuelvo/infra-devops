# Guía de usuario de Terraform y Ansible

Los comandos se ejecutan desde la raíz del repositorio. `staging` y
`production` son roots distintos y nunca comparten state.

## Preparar y validar Terraform

Elegir un root y crear su archivo local:

```bash
TF_ROOT=terraform/environments/staging/replicas
# TF_ROOT=terraform/environments/production/replicas
cp "$TF_ROOT/terraform.tfvars.example" "$TF_ROOT/terraform.tfvars"
```

Completar la VM primaria de referencia, red, región, flavor, imagen y clave
pública operativa. Mantener inicialmente `replica_count = 0`. La primaria nunca se
importa ni administra desde estos roots.

```bash
terraform fmt -check -recursive terraform
terraform -chdir="$TF_ROOT" init -backend=false
terraform -chdir="$TF_ROOT" validate
terraform -chdir="$TF_ROOT" test
```

Los tests usan OpenStack simulado y no crean recursos. Repetirlos en ambos
roots cuando cambien el módulo o cloud-init.

## Preparar Ansible

Ansible se instala solo en el controlador; la VM necesita Python y SSH:

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r ansible/requirements-dev.txt
ansible-galaxy collection install -r ansible/requirements.yml
cp ansible/inventories/staging/hosts.example.yml ansible/inventories/staging/hosts.yml
cp ansible/vars/deploy-keys.example.yml ansible/vars/deploy-keys-staging.yml
cp ansible/vars/deploy-keys.example.yml ansible/vars/deploy-keys-production.yml
```

Reemplazar las IP ficticias y cada clave pública con la clave de deployment de
su ambiente. Para una clave privada administrativa con nombre
no estándar, agregar `ansible_ssh_private_key_file` solo al inventario ignorado.
Validar los archivos antes de conectarse:

```bash
ansible-inventory -i ansible/inventories/staging/hosts.yml --graph
ansible-playbook -i ansible/inventories/staging/hosts.yml \
  -e @ansible/vars/deploy-keys-staging.yml \
  ansible/playbooks/configure-application-nodes.yml --syntax-check
ansible-lint ansible/playbooks ansible/roles
```

## Configurar y verificar una réplica

El playbook espera SSH y cloud-init, y se reconecta si la actualización inicial
reinicia la instancia.

```bash
ssh ubuntu@IP_DE_LA_REPLICA cloud-init status --wait

ansible-playbook -i ansible/inventories/staging/hosts.yml \
  -e @ansible/vars/deploy-keys-staging.yml \
  -e environment_name=staging \
  --limit staging-replica-01 \
  ansible/playbooks/configure-application-nodes.yml

ansible-playbook -i ansible/inventories/staging/hosts.yml \
  -e @ansible/vars/deploy-keys-staging.yml \
  --limit staging-replica-01 \
  ansible/playbooks/verify-application-nodes.yml
```

Para ejecutar dos pasadas de configuración y exigir idempotencia en la segunda:

```bash
ansible/tests/check-idempotence.sh \
  ansible/inventories/staging/hosts.yml \
  staging-replica-01 \
  ansible/vars/deploy-keys-staging.yml \
  staging
```

## Escalado de réplicas desde GitHub Actions

Ejecutar `Scale replicas`, elegir staging o producción e indicar la cantidad
total deseada. Una cantidad igual termina sin aplicar; una mayor crea, configura
e hidrata únicamente los índices faltantes; una menor elimina primero los índices
más altos, espera 60 segundos de drenaje y después destruye las VMs y verifica
la primaria y todas las réplicas supervivientes. El apply de producción espera la
aprobación de `production-infrastructure`; state y releases se vuelven a
validar antes de aplicar y desplegar.

Si Terraform terminó pero Ansible o una aplicación fallaron, usar **Re-run
failed jobs** sobre el mismo run. Un `run_attempt` posterior retoma una alta o
baja ya aplicada desde la fase posterior correspondiente. Una ejecución manual nueva con la
misma cantidad se considera sin cambios y no reconfigura nodos.

Cada deploy exitoso publica en su GitHub Deployment el tag y la referencia por
digest mediante `environment.url`. Antes de la primera alta deben haberse
ejecutado al menos una vez los workflows actualizados de API, Web App,
Admin Web App y gateway en el ambiente. Para publicar el gateway, crear y subir un tag `vX.Y.Z`: el
pipeline ejecuta CI, publica la imagen, despliega staging y espera la aprobación
de producción. El mismo digest se promueve entre ambos ambientes.

Durante un alta, el gateway usa Compose, plantillas y configuración del tag
registrado como exitoso para ese ambiente. Los cambios posteriores en `main` no
afectan a las nuevas réplicas hasta publicar y desplegar otra release.

En Infisical, para cada ambiente, usar rutas consistentes:

```text
/infrastructure  # R2, OpenStack, topología privada y claves del operador
/deployments     # claves deploy, GHCR y certificado del gateway
/api             # configuración privada de API
/webapp          # configuración privada de Web App
/webapp-admin    # configuración privada de Admin Web App
```

`/infrastructure` debe incluir `DATADOG_API_KEY`, `TF_PRIMARY_INSTANCE_NAME`,
`TF_PRIMARY_INSTANCE_IPV4`, `TF_PUBLIC_NETWORK_ID`, `CLOUDFLARE_API_TOKEN`,
`CLOUDFLARE_ACCOUNT_ID` y `CLOUDFLARE_POOL_ID`. Región, imagen y flavor
están versionados en cada root. `terraform.tfvars.example` es únicamente la
plantilla para crear un `terraform.tfvars` local ignorado; no contiene ni
representa los valores efectivos de CI.

No se requieren GitHub Actions Variables para Terraform. Crear ambos buckets
R2 privados y el environment GitHub `production-infrastructure` con aprobación
requerida. No guardar cantidades de réplicas ni inventarios derivados en
Infisical.

## Firebase Cloud Messaging de la API

La API ya lee `FCM_ENABLED`, `FCM_PROJECT_ID`, `FCM_TIMEOUT` y
`GOOGLE_APPLICATION_CREDENTIALS`. Configurar Infisical por ambiente:

| Ruta | Clave | Valor |
| --- | --- | --- |
| `/deployments` | `FCM_SERVICE_ACCOUNT_JSON` | Contenido completo del JSON privado de la cuenta de envío, sin base64 |
| `/api` | `FCM_PROJECT_ID` | ID del proyecto Firebase del ambiente |

El ID del proyecto también se administra en Infisical por decisión del equipo.
Aunque identifica el proyecto, no autentica al servidor. La credencial JSON sí
contiene una clave privada y permite actuar como la cuenta de servicio.

La configuración pública queda en `deploy/api/config/staging.conf` y `prod.conf`:

```dotenv
FCM_ENABLED=true
FCM_TIMEOUT=5s
GOOGLE_APPLICATION_CREDENTIALS=/etc/loresuelvo/api/firebase.json
```

No es necesario duplicar estos tres valores en Infisical. Si ya existen en
`/api`, sus valores prevalecen sobre los `.conf`: eliminar esos overrides o
alinearlos antes de desplegar.

El proyecto staging identificado en las variables de Consumer es
`loresuelvo-staging`, número `987303970692`. Su App ID de App Distribution es
`1:987303970692:android:ff891663751a63b9d83fd1`. Producción debe usar un proyecto
separado, aún pendiente de verificar. Habilitar `fcm.googleapis.com` y usar una
cuenta dedicada al envío con `roles/firebasecloudmessaging.admin` en el proyecto
destinatario, separada de la cuenta de App Distribution.

Una cuenta de servicio es una identidad para programas: en este caso, la API
la utiliza para autenticarse ante Google y enviar notificaciones. El nombre
`FCM_SERVICE_ACCOUNT_JSON` es el nombre del secreto que usa este despliegue;
Google entrega un archivo JSON, no una variable con ese nombre.

Para obtenerlo, repetir por ambiente:

1. Abrir Google Cloud Console y seleccionar el proyecto Firebase correspondiente.
2. En **IAM y administración → Cuentas de servicio → Crear cuenta de servicio**,
   crear una cuenta dedicada, por ejemplo `loresuelvo-fcm`.
3. Otorgarle en ese proyecto el rol **Firebase Cloud Messaging API Admin**
   (`roles/firebasecloudmessaging.admin`), que permite enviar mensajes.
4. Abrir la cuenta y entrar a **Claves → Agregar clave → Crear clave → JSON**.
   Se descargará el archivo con campos como `client_email` y `private_key`.
5. Copiar el contenido completo del archivo, desde `{` hasta `}`, al secreto
   `FCM_SERVICE_ACCOUNT_JSON` de Infisical, path `/deployments`, en el ambiente
   correspondiente. No convertirlo a base64 ni copiar solo `private_key`.
6. En `/api`, cargar `FCM_PROJECT_ID` con el ID del proyecto destinatario y
   verificar que la API `fcm.googleapis.com` esté habilitada antes de desplegar.

No reutilizar la cuenta de App Distribution. El JSON privado tampoco es el
`google-services.json` de Android y no debe ir en Git ni en los APKs.
Referencias: [crear una clave JSON](https://docs.cloud.google.com/iam/docs/keys-create-delete)
y [permisos de FCM](https://docs.cloud.google.com/iam/docs/roles-permissions/firebasecloudmessaging).

`GOOGLE_APPLICATION_CREDENTIALS` **es una ruta dentro del contenedor**, elegida
por infraestructura; no es un valor que se copie desde Firebase. Ya está fijada
en `deploy/api/config/staging.conf` y `prod.conf`:

```dotenv
GOOGLE_APPLICATION_CREDENTIALS=/etc/loresuelvo/api/firebase.json
```

No hace falta agregar esa variable a Infisical. El flujo existente la incorpora
a `api.env`. Los workflows preparan el JSON en `$RUNNER_TEMP/firebase.json` y
Ansible lo copia a `/etc/loresuelvo/api/firebase.json` en cada nodo con permisos
`0600`, dentro del directorio privado existente. Compose monta ese archivo en
la misma ruta, en solo lectura, únicamente para `api`. La biblioteca de Google
lee el archivo indicado por la variable y obtiene los tokens de acceso para FCM.
Ver [autorización oficial de FCM](https://firebase.google.com/docs/cloud-messaging/send/v1-api).

Push queda habilitado en los dos `.conf`. Antes del próximo despliegue, cargar
la credencial y el proyecto en ambos ambientes: sin el secreto, el workflow
prepara un archivo vacío y la API no puede arrancar con FCM activo. Cambiar el
repositorio no configura Firebase ni carga secretos automáticamente. Para
desactivar, poner `FCM_ENABLED=false` en el `.conf` del ambiente y redesplegar
todos los nodos, revisando que Infisical no sobrescriba ese valor; WebSocket y operaciones
de negocio continúan. Al rotar el JSON, el playbook recrea el contenedor para
cargar la nueva credencial. Revocar la clave anterior después de verificar el
despliegue. Releases y altas de réplicas reciben el mismo archivo del ambiente.

Para Android, registrar los packages `com.loresuelvo.consumer` y
`com.loresuelvo.serviceprovider`, con registros adicionales `.dev` y `.staging`.
Prestador recibe `google-services.json` en `app/src/<flavor>/`. Consumer utiliza
`FIREBASE_APPLICATION_ID`, `FIREBASE_API_KEY`, `FIREBASE_PROJECT_ID` y
`FIREBASE_SENDER_ID`, con sufijos `_STAGING` y `_PROD` para esos flavors.
Coordinar su entrega antes de Gradle con los responsables de los workflows
Android; App Distribution no sustituye esa configuración.

El cierre de infra #8 requiere verificar HTTPS saliente hacia
`oauth2.googleapis.com` y `fcm.googleapis.com` desde los nodos, un envío FCM
data-only al dispositivo y otro originado por una operación real de API.
Comprobar destinatario/app/binding y que las réplicas no multipliquen intentos;
un único popup no alcanza porque Android deduplica. Registrar evidencia
sanitizada en `results/`, sin claves ni tokens completos. Estas pruebas remotas
siguen pendientes. No se requieren nuevos puertos entrantes ni servicios.

Para API local y app Dev, usar teléfono con Google Play o emulador Google
APIs/Play e Internet para FCM. Con USB: `adb reverse tcp:8080 tcp:8080` y
`API_URL=http://127.0.0.1:8080`; alternativamente usar la IP LAN del backend.
Montar también la credencial si la API local corre en Docker. AOSP queda para
pruebas simuladas; staging y producción conservan HTTPS.

## Despliegue de Admin Web App

El repositorio `LoResuelvo/loresuelvo-admin-webapp` invoca el workflow reutilizable
`.github/workflows/deploy-admin-webapp.yml` desde un tag `vX.Y.Z`, con los mismos
inputs `image-ref` y `release-tag` que Web App. `image-ref` debe ser un digest
`ghcr.io/loresuelvo/gestion@sha256:…`. El caller debe conceder `contents: read`,
`id-token: write` y `deployments: write`. El flujo despliega staging y luego
producción, respetando la aprobación de su GitHub Environment.

Antes del primer despliegue, volver a ejecutar la configuración Ansible sobre
los nodos existentes para crear `/opt/loresuelvo/admin-webapp` y
`/etc/loresuelvo/admin-webapp`. En Infisical, preparar `/webapp-admin` por ambiente
con `AUTH0_CLIENT_ID`, `AUTH0_CLIENT_SECRET` y `AUTH0_SECRET` de la aplicación
Admin, y autorizar su lectura a la identidad OIDC del workflow. Los valores
públicos `AUTH0_DOMAIN`, `AUTH0_AUDIENCE` y `AUTH0_CONNECTION` se configuran
por ambiente en `deploy/admin-webapp/config/{staging,prod}.conf`, junto con
`APP_URL` y `API_URL`. La conexión debe ser la dedicada a Admin en ese ambiente.

`AUTH0_CONNECTION` queda vacío hasta confirmar el nombre real de la conexión
de Admin en cada ambiente. Completarlo antes de desplegar: el código actual de
Admin lo exige y Ansible detiene el despliegue con un mensaje explícito si falta.
Se consulta en Auth0, Applications → Applications → aplicación Admin → Connections.
Una vez completados y publicados los valores en infra, reintentar la release
fallida de Admin desde GitHub Actions.

El despliegue incluye la primaria y todas las réplicas existentes. Cada nodo
registra la versión en `/opt/loresuelvo/admin-webapp/CURRENT_RELEASE` tras superar
el healthcheck. Antes de crear nuevas réplicas debe existir un Deployment exitoso
de Admin en ese ambiente; el escalado recupera esa versión por digest y verifica
`https://gestion-test.loresuelvo.com.ar/` o `https://gestion.loresuelvo.com.ar/`
en cada nodo antes de habilitarlo.

## Puesta en marcha de Cloudflare

Cloudflare se configura desde su panel, fuera de Terraform. Por ambiente:

1. Crear el Load Balancer canónico: `test.loresuelvo.com.ar` en staging y
   `loresuelvo.com.ar` en producción.
2. Crear un pool con steering aleatorio, mínimo saludable 1 y el endpoint fijo
   `<ambiente>-primary` apuntando a `TF_PRIMARY_INSTANCE_IPV4`.
3. Asociar un monitor HTTPS, puerto 443, ruta `/__gateway_ready`, código `200`,
   región Eastern North America y `Host` de API (`api-test.loresuelvo.com.ar`
   o `api.loresuelvo.com.ar`).
4. Configurar afinidad Cookie, Zero Downtime Failover Sticky, Adaptive Routing
   desactivado, shedding desactivado, proximity desactivado y sin custom rules.
5. Crear los aliases DNS proxied como CNAME al hostname canónico: `api-test` en
   staging, junto con `gestion-test`; `api`, `www` y `gestion` en producción.
6. Guardar el Account ID y el Pool ID en Infisical y ejecutar `Scale replicas`
   sólo cuando se quiera cambiar la cantidad de VMs.

El flujo conserva el endpoint primario y cualquier endpoint manual cuyo nombre
no siga `<ambiente>-replica-NN`. Rollback: restaurar los DNS anteriores y luego
deshabilitar el Load Balancer.
Configurar en Cloudflare una
alerta de uso acorde al presupuesto; el provider no administra alertas de
facturación. La referencia inicial es USD 5/mes hasta dos orígenes, USD 5 por
origen adicional y 500.000 consultas DNS incluidas; confirmar el precio vigente
antes de activar producción.

## Prueba temporal en OVH

Se requieren OpenRC y contraseña vigentes, clave privada operativa, cuota para
una VM y keypair, `terraform.tfvars` real y claves de deployment reales.

1. Establecer temporalmente `replica_count = 1` en el root de staging.
2. Generar y revisar un plan que agregue solo esa VM y su keypair; aplicar
   manualmente.
3. Generar un inventario temporal con la primaria de Infisical y los outputs de
   réplicas, y ejecutar los playbooks de configuración y verificación.
4. Revisar el resultado del playbook de verificación.
5. Quitar la réplica del mapa, revisar que el plan destruya solo la VM temporal
   y su keypair, aplicar y confirmar su ausencia en Terraform y OpenStack.

La limpieza se realiza incluso si falla una validación. Nunca se apunta a una
VM fija operativa.

## Archivos locales

Nunca agregar a Git:

```text
.env
*openrc*
terraform.tfvars
ansible/inventories/*/hosts.yml
ansible/vars/deploy-keys-staging.yml
ansible/vars/deploy-keys-production.yml
claves privadas SSH
*.tfstate
*.tfstate.*
*.tfplan
.terraform/
.venv/
```

Comprobar cualquier archivo dudoso con `git check-ignore -v RUTA`. Los state,
planes y tfvars históricos en `terraform/` se conservan localmente; no se
mueven ni borran automáticamente.
