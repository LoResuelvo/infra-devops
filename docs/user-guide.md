# Guía de usuario de Terraform y Ansible

Los comandos se ejecutan desde la raíz del repositorio. `test` y `production`
son roots distintos y nunca comparten state local.

## Preparar y validar Terraform

Elegir un root y crear su archivo local:

```bash
TF_ROOT=terraform/environments/test/replicas
# TF_ROOT=terraform/environments/production/replicas
cp "$TF_ROOT/terraform.tfvars.example" "$TF_ROOT/terraform.tfvars"
```

Completar la VM primaria de referencia, red, región, flavor, imagen y clave
pública operativa. Mantener inicialmente `replicas = {}`. La primaria nunca se
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
cp ansible/inventories/test/hosts.example.yml ansible/inventories/test/hosts.yml
cp ansible/vars/deploy-keys.example.yml ansible/vars/deploy-keys.yml
```

Reemplazar la IP ficticia y la clave pública. Para una clave privada con nombre
no estándar, agregar `ansible_ssh_private_key_file` solo al inventario ignorado.
Validar los archivos antes de conectarse:

```bash
ansible-inventory -i ansible/inventories/test/hosts.yml --graph
ansible-playbook -i ansible/inventories/test/hosts.yml \
  -e @ansible/vars/deploy-keys.yml \
  ansible/playbooks/configure-application-nodes.yml --syntax-check
ansible-lint ansible/playbooks ansible/roles
```

## Configurar y verificar una réplica

Esperar que cloud-init y SSH estén disponibles. Un reboot durante la
actualización inicial es posible.

```bash
ssh ubuntu@IP_DE_LA_REPLICA cloud-init status --wait

ansible-playbook -i ansible/inventories/test/hosts.yml \
  -e @ansible/vars/deploy-keys.yml \
  --limit test-ansible-validation-01 \
  ansible/playbooks/configure-application-nodes.yml

ansible-playbook -i ansible/inventories/test/hosts.yml \
  -e @ansible/vars/deploy-keys.yml \
  --limit test-ansible-validation-01 \
  ansible/playbooks/verify-application-nodes.yml
```

Para ejecutar dos pasadas de configuración y exigir idempotencia en la segunda:

```bash
ansible/tests/check-idempotence.sh \
  ansible/inventories/test/hosts.yml \
  test-ansible-validation-01 \
  ansible/vars/deploy-keys.yml
```

## Prueba temporal en OVH

Se requieren OpenRC y contraseña vigentes, clave privada operativa, cuota para
una VM y keypair, `terraform.tfvars` real y claves de deployment reales.

1. Declarar únicamente `test-ansible-validation-01` en `replicas` del root de
   test.
2. Generar y revisar un plan que agregue solo esa VM y su keypair; aplicar
   manualmente.
3. Ejecutar `scripts/configure-test-ansible-validation.sh`. El script obtiene la
   única IP desde `replica_ipv4`, genera el inventario ignorado, espera
   cloud-init/SSH, ejecuta dos pasadas y verifica `changed=0` en la segunda.
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
ansible/vars/deploy-keys.yml
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
