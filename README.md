# LoResuelvo — infraestructura y DevOps

Infraestructura como código y herramientas operativas del equipo LoResuelvo.
Terraform modela réplicas de aplicación en OVHcloud/OpenStack mediante dos
roots independientes: test y producción. Las VMs primarias existentes solo
forman parte del inventario de salida y están completamente fuera del lifecycle
de Terraform.

## Estructura

```text
terraform/
├── environments/
│   ├── test/replicas/        # root y state local de test
│   └── production/replicas/  # root y state local de producción
├── modules/application-node/ # imagen, keypair y VM reutilizables
└── cloud-init.yaml.tftpl     # bootstrap básico heredado
```

Cada root recibe un mapa `replicas`. Su valor por defecto es `{}`: inicializar,
validar o probar el código no decide crear VMs. Los nombres son las claves
estables del mapa y los outputs exponen `replica_ids`, `replica_ipv4`,
`replicas` y el inventario combinado `deployment_hosts`.

## Validación segura

```bash
terraform fmt -check -recursive terraform
terraform -chdir=terraform/environments/test/replicas init -backend=false
terraform -chdir=terraform/environments/test/replicas validate
terraform -chdir=terraform/environments/test/replicas test
terraform -chdir=terraform/environments/production/replicas init -backend=false
terraform -chdir=terraform/environments/production/replicas validate
terraform -chdir=terraform/environments/production/replicas test
```

Los tests usan un provider mock: no requieren credenciales ni acceden a OVH.
No se debe automatizar ni ejecutar `terraform apply` hasta revisar un plan y,
antes del provisioning automatizado, migrar a un backend remoto compartido con
locking.

## Documentación

- [Guía de usuario](docs/user-guide.md): preparación, comandos por ambiente,
  outputs y verificación operativa.
- [Guía técnica](docs/technical-guide.md): state, límites de lifecycle,
  topología y tests.
