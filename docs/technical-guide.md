# Guía técnica de infraestructura y configuración

## Separación de responsabilidades

| Capa | Responsabilidad |
|---|---|
| Terraform | Decide cuántas réplicas existen en staging y producción; no administra Cloudflare. |
| Cloudflare manual | Mantiene Load Balancer, pool, monitor, DNS, steering y endpoint primario. |
| GitHub Actions | Coordina Terraform, Ansible y los endpoints de réplicas del pool. |
| `application-node` | Crea keypair, VM, red y entrega `user_data`. |
| Cloud-init | Deja Ubuntu accesible como `ubuntu` con Python, sudo y SSH seguro. |
| Ansible | Configura usuario, Docker, firewall, actualizaciones y nodo. |
| Deployments | Instalan API, Web App y gateway, y publican la versión activa. |

## Topología y lifecycle

`terraform/environments/staging/replicas` y
`terraform/environments/production/replicas` son roots independientes. Cada
uno mantiene su propia configuración, directorio de trabajo y state remoto.

`replica_count` genera claves deterministas terminadas en `-replica-NN`; el
default cero crea cero recursos. El módulo registra la clave pública operativa,
busca la imagen Ubuntu más reciente y crea la VM conectada a la red indicada.
El lifecycle ignora cambios posteriores de `image_id`, por lo que una imagen
nueva solo afecta nodos nuevos.

El escalado hacia abajo deshabilita primero los índices más altos en el pool,
confirma que Cloudflare los informa deshabilitados, espera 60 segundos, destruye VM
y keypair y elimina finalmente los endpoints del pool. Esta ventana corta puede
interrumpir sesiones HTTP o WebSockets que sigan activas.

Cada root versiona su región, imagen y flavor. Recibe `public_network_id` y
`operator_ssh_public_key` desde Infisical, además del `replica_count` solicitado
por el workflow. Los outputs exponen cantidad, nombres e IPv4 ordenados. El
inventario combina esos outputs con la primaria obtenida directamente de
Infisical, incluida cuando el state todavía está vacío.

## State y secretos

Cada root de réplicas usa un backend S3 parcial, cifrado y con `use_lockfile`,
sobre un bucket R2 privado por ambiente. `*.tfstate`, `*.tfvars`, planes y `.terraform/`
están ignorados. Bucket, endpoint y credenciales se pasan al ejecutar `init`.
`CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID` y `CLOUDFLARE_POOL_ID` se leen
de `/infrastructure` en Infisical. El token sólo necesita permiso de edición
`Load Balancing: Monitors and Pools`. Credenciales OpenStack, claves privadas,
inventarios reales y claves de deployment nunca se declaran en archivos
versionados.

Actions sólo considera propios los endpoints llamados
`<ambiente>-replica-NN`. Conserva los demás endpoints y valida antes de escribir
que `<ambiente>-primary` exista, esté habilitado y coincida con
`TF_PRIMARY_INSTANCE_IPV4`. La actualización parcial del pool no modifica su
monitor, regiones, steering ni demás configuración manual.

## Cloud-init mínimo

`cloud-init/application-node.yaml` es el `user_data` común. Su marca es
`2026-09-04.1`. Actualiza Ubuntu, permite el reboot inicial cuando los paquetes
lo requieren, instala Python 3, sudo y UFW, abre únicamente SSH y restringe el
acceso a `ubuntu` con clave pública. Es deliberadamente ajeno a Docker,
`deploy` y las aplicaciones.

## Configuración Ansible

El controlador usa Python 3.12 y `ansible-core 2.21.3`; el nodo remoto solo
necesita Python y SSH. `ansible/requirements.yml` fija
`community.general 13.3.0` y `community.docker 5.2.2`. Los roles aplican:

- `base_node`: paquetes base, actualizaciones de seguridad sin reboot,
  `/opt/loresuelvo`, `/etc/loresuelvo` y normalización de las marcas de
  bootstrap y configuración, incluso en instancias fijas reinstaladas;
- `docker`: repositorio oficial, Docker CE/CLI `29.7.2`, containerd `2.3.3`,
  Buildx `0.36.1`, Compose `5.4.0`, paquetes en hold, rotación de logs y
  `live-restore`;
- `datadog_agent`: Agent 7 en Docker con métricas del host y contenedores y
  recolección de logs, etiquetados por ambiente y rol;
- `deploy_user`: usuario sin contraseña, claves requeridas, grupo `docker`,
  directorios de API/Web App/gateway con permisos restrictivos y ampliación de
  `AllowUsers` a `ubuntu deploy`;
- `firewall`: UFW 22/80/443 y política persistente de `DOCKER-USER` que admite
  conexiones iniciadas por los bridges Docker, respuestas establecidas y
  tráfico web entrante, y descarta el resto.

Ansible crea `app-network`, `/opt/loresuelvo/{api,gateway,webapp}` con modo
`0750` y los directorios privados `/etc/loresuelvo/api`,
`/etc/loresuelvo/gateway/tls` y `/etc/loresuelvo/webapp` con modo `0700`. Las
claves solo se suministran desde `ansible/vars/deploy-keys-staging.yml` o
`ansible/vars/deploy-keys-production.yml`, ambos ignorados. El mismo playbook y
roles se usan para los dos ambientes; solo cambia la clave pública suministrada.

## Validación

Los despliegues remotos usan los módulos de Docker Compose, copia, plantillas y
healthchecks de Ansible. El inventario privado se genera durante el job y no se
publica como output ni artifact.
Los dominios del gateway se declaran en `deploy/gateway/config/{staging,prod}.conf`.
Ansible prepara también `/opt/loresuelvo/gateway/nginx` como `deploy:deploy`,
modo `0750`: ejecutar el setup antes del primer despliegue en un nodo nuevo.
La versión de configuración correspondiente es `2026-09-10.1`. Cada despliegue
publica tag y digest inmutable en la URL de su GitHub Deployment. El alta de
réplicas consulta el último Deployment exitoso de API, Web App y gateway para
el ambiente. El modo `hydrate` de la API instala un nodo nuevo sin ejecutar
migraciones; estas siguen perteneciendo únicamente al despliegue normal.
El chequeo de Admin valida la ruta y virtual host del gateway; la aplicación
Admin tiene un lifecycle de despliegue separado y no forma parte de esta alta.
Las comprobaciones locales del flujo se ejecutan con
`python3 -m unittest discover -s scripts/tests`.

Los tests mock de Terraform verifican cero réplicas por defecto, identidades
estables, inventario y cloud-init YAML válido con SSH/Python/UFW y sin Docker ni
`deploy`. La capa Ansible se valida con inventario, syntax-check y
`ansible-lint`.

`DATADOG_API_KEY` se obtiene exclusivamente del entorno del controlador (en CI,
desde `/infrastructure` de Infisical). Para configurar localmente, exportarla y
pasar `-e environment_name=staging` o `production`. El rollout inicial requiere
ejecutar el playbook una vez sobre las VMs actuales de cada ambiente.

En una réplica configurada, `verify-application-nodes.yml` comprueba usuarios y
claves, SSH, paquetes y holds de Docker, daemon, Compose, `app-network`,
servicios, el estado y healthcheck del Agent, directorios raíz, UFW,
`DOCKER-USER`, actualizaciones y marcas. El
playbook también verifica propietario y modo de cada directorio de despliegue.
El script `ansible/tests/check-idempotence.sh` ejecuta dos pasadas y exige
`changed=0`, `unreachable=0` y `failed=0` en la segunda.

Los tests locales no crean recursos ni acceden a OVH. Una prueba real debe usar
exclusivamente una réplica temporal de staging, con planes de
alta y baja revisados, y debe destruirla incluso si una validación falla.
