# Guía de usuario de Terraform

Los comandos se ejecutan desde la raíz del repositorio con Terraform 1.6 o
posterior. `test` y `production` son roots distintos y nunca comparten state
local.

## Preparar un ambiente

Elegir un root:

```bash
TF_ROOT=terraform/environments/test/replicas
# TF_ROOT=terraform/environments/production/replicas
cp "$TF_ROOT/terraform.tfvars.example" "$TF_ROOT/terraform.tfvars"
```

Editar el archivo local con el nombre e IPv4 de la VM primaria existente, red,
región, flavor, imagen y clave pública operativa. La primaria es una entrada para
el inventario; jamás se importa ni administra desde este root.

Dejar inicialmente:

```hcl
replicas = {}
```

El ejemplo no contiene valores operativos. No copiar claves privadas,
contraseñas, OpenRC ni IPs reales a archivos versionados.

## Validar sin credenciales

```bash
terraform fmt -check -recursive terraform
terraform -chdir="$TF_ROOT" init -backend=false
terraform -chdir="$TF_ROOT" validate
terraform -chdir="$TF_ROOT" test
```

Los tests simulan OpenStack y no crean recursos. Repetirlos en ambos roots
antes de revisar cambios compartidos del módulo o cloud-init.

## Revisar una futura réplica

Cuando exista autorización explícita, agregar una clave estable al mapa:

```hcl
replicas = {
  "test-replica-01" = {}
}
```

Las credenciales de OVH se cargan localmente:

```bash
source .env
source ~/.config/loresuelvo/openstack/openrc.sh <<< "$OS_PASSWORD"
terraform -chdir="$TF_ROOT" plan -out=tfplan
terraform -chdir="$TF_ROOT" show tfplan
```

Revisar nombres, región, flavor, imagen, cantidad de altas/bajas y ausencia de
la VM primaria. Estos issues no autorizan `apply`: la primera réplica se creará
en una etapa posterior mediante un plan revisado y una ejecución autorizada.
No conectar este comando a CI antes de contar con backend remoto y locking.

## Consultar inventario

Sobre un state ya materializado:

```bash
terraform -chdir="$TF_ROOT" output replicas
terraform -chdir="$TF_ROOT" output deployment_hosts
```

`deployment_hosts` devuelve la primaria y las réplicas ordenadas. Está pensado
para la futura automatización multi-host, no para incorporar la primaria al
lifecycle de Terraform.

## Archivos locales

Nunca agregar a Git:

```text
.env
*openrc*
terraform.tfvars
*.tfstate
*.tfstate.*
*.tfplan
.terraform/
plan.md
```

Comprobar cualquier archivo dudoso con `git check-ignore -v RUTA`. Los state,
plan y tfvars históricos en `terraform/` se conservan localmente y no deben
moverse o borrarse automáticamente.
