# LoResuelvo — infraestructura y DevOps

Infraestructura como código y herramientas operativas del equipo LoResuelvo.

La implementación actual permite crear una instancia efímera Ubuntu en el
proyecto OVHcloud Public Cloud del equipo. Terraform administra la instancia y
su clave pública; cloud-init configura SSH y el firewall durante el primer
arranque.

## Arquitectura actual

```text
Terraform
   │
   ▼
OVHcloud Public Cloud / OpenStack / BHS5
   ├── instancia d2-4 con Ubuntu 24.04
   ├── red pública Ext-Net
   └── security group default
             │
             ▼
        UFW en Ubuntu
        ├── entrada bloqueada por defecto
        └── SSH 22 permitido
             │
             ▼
        OpenSSH
        ├── solo clave pública
        ├── usuario ubuntu
        ├── sin contraseñas
        └── sin login de root
```

## Documentación

- [Guía de usuario](docs/user-guide.md): preparación local, flujo
  `init/plan/apply`, conexión SSH, verificación y destrucción.
- [Guía técnica](docs/technical-guide.md): arquitectura, glosario,
  explicación del código Terraform y guía de cloud-init.

## Uso rápido

Con acceso autorizado al proyecto del equipo y los archivos locales ya
preparados:

```bash
source .env
source ~/.config/loresuelvo/openstack/openrc.sh <<< "$OS_PASSWORD"

terraform -chdir=terraform init
terraform -chdir=terraform validate
terraform -chdir=terraform plan -out=tfplan
terraform -chdir=terraform show tfplan
terraform -chdir=terraform apply tfplan
```

La instancia se factura mientras exista. Al finalizar las pruebas:

```bash
terraform -chdir=terraform plan -destroy -out=destroy.tfplan
terraform -chdir=terraform show destroy.tfplan
terraform -chdir=terraform apply destroy.tfplan
```

Detener o apagar la máquina no reemplaza la destrucción del recurso.
