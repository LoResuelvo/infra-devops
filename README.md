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
└── modules/application-node/ # imagen, keypair, VM y user_data
cloud-init/
└── application-node.yaml     # acceso mínimo para Ansible
ansible/
├── inventories/              # ejemplos; hosts.yml reales ignorados
├── playbooks/                # configuración y verificación
└── roles/                    # nodo base, Docker, deploy y firewall
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

## Bootstrap y configuración

Cloud-init solo deja Ubuntu administrable como `ubuntu`: actualización inicial,
Python, sudo, UFW con SSH y autenticación SSH por clave. Ansible crea `deploy`,
instala las versiones fijadas de Docker, configura firewall, actualizaciones y
los directorios raíz `/opt/loresuelvo` y `/etc/loresuelvo`. Los deployments de
API y webapp crearán sus propios subdirectorios posteriormente.

Ansible se instala únicamente en el equipo controlador:

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r ansible/requirements-dev.txt
ansible-galaxy collection install -r ansible/requirements.yml
```

Las versiones fijadas son `ansible-core 2.21.3`, `ansible-lint 26.8.0`,
`community.general 13.3.0` y `community.docker 5.2.2`.

## Documentación

- [Guía de usuario](docs/user-guide.md): preparación, comandos por ambiente,
  configuración Ansible y prueba temporal en OVH.
- [Guía técnica](docs/technical-guide.md): state, límites de lifecycle,
  responsabilidades, bootstrap y diseño de roles.
