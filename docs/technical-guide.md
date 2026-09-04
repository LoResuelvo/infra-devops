# Guía técnica de Terraform y bootstrap

## Topología y lifecycle

`terraform/environments/test/replicas` y
`terraform/environments/production/replicas` son roots independientes. Cada
uno mantiene su propia configuración, variables, lock file, directorio de
trabajo y state local. Ambos llaman a `modules/application-node` para crear
exclusivamente réplicas.

```text
primary_instance (input, no administrado) ─┐
                                           ├─ deployment_hosts
replicas (map for_each) ─ módulo ─ VMs ────┘
```

`primary_instance` contiene solo `name` e `ipv4`. No alimenta ningún `resource`
ni `data source`, por lo que Terraform no puede modificar o destruir la VM
primaria. `replicas` es `map(object({}))`; cada clave es a la vez la identidad
de `for_each` y el nombre estable de la VM. El default `{}` produce cero
recursos.

El módulo consulta la imagen, registra un keypair que contiene únicamente la
clave pública operativa y crea una instancia conectada a la red pública. Las
credenciales OpenStack siguen llegando mediante variables `OS_*`; ninguna se
declara en HCL.

## State

El state relaciona una dirección como
`module.replica["test-replica-01"]` con el ID real asignado por OpenStack. Sin
esa relación Terraform podría intentar duplicar recursos o no conocer el
objeto que debe actualizar o destruir.

Por ahora cada root usa state local e independiente. `*.tfstate`, `*.tfvars`,
`.terraform/` y planes están ignorados. Los artefactos locales que pertenecían
al root anterior se conservan en `terraform/` como respaldo histórico: no se
borran, migran ni reutilizan automáticamente. Antes de automatizar provisioning
se debe diseñar una migración explícita a un backend remoto compartido, cifrado
y con locking. Hasta entonces no se automatiza `apply`.

## Variables y outputs

Cada root recibe:

- `environment` y `primary_instance`;
- `replicas`, vacío por defecto;
- `region`, `image_name`, `flavor_name` y `public_network_id`;
- `operator_ssh_public_key`.

Los ejemplos versionados usan direcciones reservadas para documentación y
claves ficticias. Los valores reales viven en un `terraform.tfvars` dentro del
root correspondiente y permanecen ignorados.

Los outputs son mapas de IDs e IPv4, el mapa completo de réplicas y
`deployment_hosts`. Este último contiene primero la primaria y luego las
réplicas ordenadas por nombre. No se exponen credenciales, claves privadas ni
user data.

## Validación sin OVH

`terraform test` usa `mock_provider "openstack"` para comprobar:

- cero réplicas con el default;
- dos nombres estables con inventario ordenado;
- inventario combinado con la primaria.

No se ejecutan planes reales ni `apply` como parte de esta validación.
