# LoResuelvo — infraestructura y DevOps

Infraestructura como código y herramientas operativas del equipo LoResuelvo.
Terraform modela réplicas de aplicación en OVHcloud/OpenStack mediante dos
roots independientes: staging y producción. Las VMs primarias existentes solo
forman parte del inventario de salida y están completamente fuera del lifecycle
de Terraform.

## Estructura

```text
terraform/
├── environments/
│   ├── staging/replicas/     # root y state remoto de staging
│   └── production/replicas/  # root y state remoto de producción
└── modules/application-node/ # imagen, keypair, VM y user_data
cloud-init/
└── application-node.yaml     # acceso mínimo para Ansible
ansible/
├── inventories/              # ejemplos; hosts.yml reales ignorados
├── playbooks/                # configuración y verificación
└── roles/                    # nodo base, Docker, deploy y firewall
```

Cada root recibe `replica_count`, cuyo valor por defecto es cero. Los nombres
se derivan de forma estable (`staging-replica-01`,
`production-replica-01`, etc.) y `for_each` garantiza que crecer solo agregue
los índices faltantes. Los outputs ordenados son `replica_count`,
`replica_names`, `replica_ipv4` y `deployment_hosts`.

## Validación segura

```bash
terraform fmt -check -recursive terraform
terraform -chdir=terraform/environments/staging/replicas init -backend=false
terraform -chdir=terraform/environments/staging/replicas validate
terraform -chdir=terraform/environments/staging/replicas test
terraform -chdir=terraform/environments/production/replicas init -backend=false
terraform -chdir=terraform/environments/production/replicas validate
terraform -chdir=terraform/environments/production/replicas test
```

Los tests usan un provider mock: no requieren credenciales ni acceden a OVH.
Los roots usan backends S3 parciales sobre buckets R2 privados separados, con
locking nativo por archivo: `loresuelvo-terraform-state-staging` y
`loresuelvo-terraform-state-production`. Endpoint y credenciales nunca se
versionan.

## Bootstrap y configuración

Cloud-init solo deja Ubuntu administrable como `ubuntu`: actualización inicial,
Python, sudo, UFW con SSH y autenticación SSH por clave. Ansible crea `deploy`,
instala las versiones fijadas de Docker, configura firewall, actualizaciones y
los directorios raíz `/opt/loresuelvo` y `/etc/loresuelvo`. También prepara
como `deploy` los directorios operativos y privados de la API, la Web App y el
gateway.

Ansible se instala únicamente en el equipo controlador:

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r ansible/requirements-dev.txt
ansible-galaxy collection install -r ansible/requirements.yml
```

Las versiones fijadas son `ansible-core 2.21.3`, `ansible-lint 26.8.0`,
`community.general 13.3.0` y `community.docker 5.2.2`.

El workflow de alta genera un inventario efímero dentro de `$RUNNER_TEMP`,
espera SSH y cloud-init y ejecuta configuración y verificación. Los despliegues normales obtienen su
inventario completo desde `deployment_hosts` mediante Terraform; Infisical ya
no almacena `DEPLOY_HOSTS`.

El workflow manual `Provision replicas` recibe el ambiente y la cantidad total deseada, rechaza
reducciones y termina sin cambios cuando coincide con el state. Producción
presenta el plan antes de requerir aprobación en `production-infrastructure`.
Las imágenes se resuelven desde los últimos GitHub Deployments exitosos del
ambiente y siempre se despliegan por digest.

## Documentación

- [Guía de usuario](docs/user-guide.md): preparación, comandos por ambiente,
  configuración Ansible y prueba temporal en OVH.
- [Guía técnica](docs/technical-guide.md): state, límites de lifecycle,
  responsabilidades, bootstrap y diseño de roles.
