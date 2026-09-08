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

## Migración única del state local a R2

Crear primero ambos buckets privados. Migrar staging antes que producción y
usar una credencial de escritura del ambiente correspondiente:

```bash
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_ENDPOINT_URL_S3=https://ACCOUNT_ID.r2.cloudflarestorage.com

terraform -chdir="$TF_ROOT" init -migrate-state \
  -backend-config="bucket=loresuelvo-terraform-state-staging"
# Para el otro root, usar loresuelvo-terraform-state-production.
terraform -chdir="$TF_ROOT" plan -detailed-exitcode
```

Confirmar que el plan termina con código 0 (sin cambios) antes de migrar el
siguiente ambiente. Conservar el state local fuera del repositorio hasta
validar la copia remota. Finalmente, iniciar dos operaciones simultáneas contra
el mismo root y confirmar que una adquiere el lock y la otra espera o falla sin
escribir. Nunca usar `-lock=false`.

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

Esperar que cloud-init y SSH estén disponibles. Un reboot durante la
actualización inicial es posible.

```bash
ssh ubuntu@IP_DE_LA_REPLICA cloud-init status --wait

ansible-playbook -i ansible/inventories/staging/hosts.yml \
  -e @ansible/vars/deploy-keys-staging.yml \
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
  ansible/vars/deploy-keys-staging.yml
```

## Alta de réplicas desde GitHub Actions

Ejecutar `Provision staging replicas` o `Provision production replicas` e
indicar la cantidad total deseada. No hay selector libre de ambiente. Una
cantidad menor falla; una cantidad igual termina sin aplicar; una mayor crea y
configura únicamente los índices faltantes. El apply de producción espera la
aprobación de `production-infrastructure` y vuelve a validar state y releases
antes de continuar.

Si Terraform terminó pero Ansible o una aplicación fallaron, usar **Re-run
failed jobs** sobre el mismo run. Un `run_attempt` posterior retoma únicamente
las réplicas creadas por el intento original. Una ejecución manual nueva con la
misma cantidad se considera sin cambios y no reconfigura nodos.

Cada deploy exitoso publica en su GitHub Deployment el tag y la referencia por
digest mediante `environment.url`. Antes de la primera alta deben haberse
ejecutado al menos una vez los workflows actualizados de API, Web App y gateway
en el ambiente. El gateway se dispara indicando explícitamente
`release-tag` e `image-ref`; API y Web App reciben esos datos desde sus
workflows de release.

Crear como variables de repositorio, por cada prefijo `STAGING` y
`PRODUCTION`:

```text
<ENV>_TF_PRIMARY_INSTANCE_NAME
<ENV>_TF_PRIMARY_INSTANCE_IPV4
<ENV>_TF_REGION
<ENV>_TF_IMAGE_NAME
<ENV>_TF_FLAVOR_NAME
<ENV>_TF_PUBLIC_NETWORK_ID
```

En Infisical, para cada ambiente, usar rutas consistentes:

```text
/infrastructure/terraform-write  # R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_ENDPOINT
/infrastructure/terraform-read   # credencial R2 distinta y de solo lectura
/infrastructure/openstack        # variables OS_* individuales
/infrastructure/ssh              # OPERATOR_SSH_* y DEPLOY_SSH_PUBLIC_KEYS_JSON
/deployments                     # clave deploy, GHCR y certificado del gateway
/api
/webapp
```

Crear ambos buckets R2 privados y el environment GitHub
`production-infrastructure` con aprobación requerida. No guardar nombres,
cantidades ni inventarios de hosts en Infisical.

## Prueba temporal en OVH

Se requieren OpenRC y contraseña vigentes, clave privada operativa, cuota para
una VM y keypair, `terraform.tfvars` real y claves de deployment reales.

1. Establecer temporalmente `replica_count = 1` en el root de staging.
2. Generar y revisar un plan que agregue solo esa VM y su keypair; aplicar
   manualmente.
3. Ejecutar el script de configuración para staging con el nodo nuevo obtenido
   de `deployment_hosts`; genera un inventario temporal y espera
   cloud-init/SSH antes de configurar y verificar.
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
plan.md
```

Comprobar cualquier archivo dudoso con `git check-ignore -v RUTA`. Los state,
planes y tfvars históricos en `terraform/` se conservan localmente; no se
mueven ni borran automáticamente.
