# LoResuelvo — infraestructura y DevOps

Infraestructura como código y herramientas operativas del equipo LoResuelvo.
Terraform modela las réplicas en OVHcloud/OpenStack. El Load Balancer, su pool,
monitor y DNS se configuran manualmente en Cloudflare; Actions sólo sincroniza
los endpoints de las réplicas. Las VMs primarias existentes solo
forman parte del inventario de salida y están completamente fuera del lifecycle
de Terraform.

## Estructura

```text
terraform/
├── environments/
│   ├── staging/replicas/     # root y state remoto de staging
│   └── production/replicas/  # root y state remoto de producción
└── modules/application-node/ # nodo de aplicación
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
`replica_names` y `replica_ipv4`. Región, imagen y flavor quedan versionados
por ambiente; la primaria y el ID de red se inyectan desde Infisical y no se
guardan en GitHub Variables ni en el state de réplicas.

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
espera SSH y cloud-init y ejecuta configuración y verificación. Los despliegues
combinan la primaria de Infisical con los outputs de réplicas de Terraform;
Infisical no almacena `DEPLOY_HOSTS`.

El workflow manual `Scale replicas` recibe el ambiente y la cantidad total
deseada. En una alta configura, despliega y verifica cada nodo antes de
habilitarlo en el pool existente de Cloudflare. En una baja deshabilita los
índices más altos, confirma que quedaron deshabilitados, espera 60 segundos y recién entonces
los destruye. Producción presenta el plan antes de requerir aprobación en
`production-infrastructure`.
Las imágenes se resuelven desde los últimos GitHub Deployments exitosos del
ambiente y siempre se despliegan por digest.

## Documentación

- [Guía de usuario](docs/user-guide.md): preparación, comandos por ambiente,
  configuración Ansible y prueba temporal en OVH.
- [Guía técnica](docs/technical-guide.md): state, límites de lifecycle,
  responsabilidades, bootstrap y diseño de roles.
