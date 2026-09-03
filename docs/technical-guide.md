# Guía técnica de la infraestructura efímera

Este documento explica la arquitectura, los términos necesarios para
mantenerla, el código Terraform y la configuración de cloud-init.

## Arquitectura y límites de confianza

```text
Equipo del operador
  ├── Terraform + provider OpenStack
  ├── OpenRC + contraseña local
  └── clave privada SSH
           │
           ▼
OVHcloud Public Cloud / OpenStack / BHS5
  ├── imagen Ubuntu 24.04
  ├── keypair con la clave pública
  └── instancia d2-4 conectada a Ext-Net
           │
           ▼
Security group "default" (permisivo)
           │
           ▼
Ubuntu / UFW
  ├── entrada denegada por defecto
  ├── TCP 22 permitido
  └── salida permitida
           │
           ▼
OpenSSH: usuario ubuntu, solo clave, sin root
```

El filtrado efectivo está actualmente dentro de la VM. El security group
`default` deja pasar tráfico hasta el host y UFW decide qué acepta Ubuntu. Una
futura cuota de Neutron permitiría agregar una capa restrictiva antes de la VM.

## Glosario

### Infraestructura como código (IaC)

Descripción versionable de infraestructura. Facilita revisión, repetibilidad,
automatización y detección de cambios.

### Terraform

Herramienta declarativa de IaC. El código expresa el estado deseado y Terraform
calcula cómo pasar del estado real a ese objetivo.

### Provider

Plugin que conecta Terraform con una API. Este repositorio usa el provider de
OpenStack para operar sobre OVHcloud.

### Resource y data source

Un resource es un objeto administrado por Terraform, como una instancia o un
keypair. Un data source consulta algo existente sin administrarlo, como la
imagen Ubuntu del catálogo.

### State

Registro que relaciona direcciones Terraform con IDs reales de OpenStack. Puede
contener información sensible y no debe publicarse. Sin un state correcto,
Terraform puede perder la relación con los recursos existentes.

### Plan, apply y destroy

- Plan: compara configuración, state e infraestructura real.
- Apply: ejecuta el plan y modifica recursos reales.
- Destroy: elimina los recursos administrados y detiene su consumo.

### Drift

Diferencia entre el código y cambios realizados manualmente o por otra
automatización sobre la infraestructura real.

### OpenStack

Plataforma utilizada por OVHcloud Public Cloud. Nova administra cómputo,
Neutron redes, Glance imágenes y Keystone identidad.

### OpenRC, Keystone y token

OpenRC exporta las variables `OS_*` que identifican endpoint, usuario, proyecto
y región. Keystone valida esas credenciales y emite un token temporal para las
operaciones posteriores.

### Región, flavor e imagen

- Región: ámbito donde existen recursos y cuotas; aquí se usa `BHS5`.
- Flavor: plantilla de vCPU, RAM, disco y red; aquí se usa `d2-4`.
- Imagen: base del sistema operativo; aquí se busca `Ubuntu 24.04`.

### Instancia y keypair

La instancia es la VM administrada por Nova. El keypair registra en OpenStack
solo la clave pública; la clave privada permanece en el equipo del operador.

### Ext-Net, port e IPv4 pública

Ext-Net es la red externa que entrega conectividad pública. Un port de
OpenStack es una interfaz virtual y no debe confundirse con un puerto TCP. Esta
configuración recibe una IPv4 directamente y no crea una Floating IP separada.

### Security group y UFW

El security group es el firewall virtual de Neutron, anterior a la VM. UFW
administra el firewall dentro de Ubuntu. Por la cuota cero de grupos y reglas,
se reutiliza `default` y UFW constituye la barrera efectiva.

### Ingress, egress y CIDR

- Ingress: tráfico que entra a la instancia.
- Egress: tráfico originado en la instancia.
- CIDR: notación de rangos IP; `/32` representa una sola IPv4.

### Cloud-init y user data

Cloud-init configura la VM durante el primer arranque. OpenStack entrega la
configuración mediante user data. Cambiarla fuerza el reemplazo de esta VM.

## Explicación del código Terraform

### `versions.tf`

Exige Terraform 1.6 o posterior y declara el provider OpenStack `~> 3.0`.
`.terraform.lock.hcl` fija la versión seleccionada y sus hashes para que el
equipo use el mismo binario.

### `providers.tf`

Configura `region = var.region`. Las credenciales no aparecen en HCL: el
provider consume las variables `OS_*` cargadas por OpenRC.

### `variables.tf`

Define y valida región, nombre, flavor, imagen, UUID de red y ruta de clave
pública. Los defaults representan el entorno compartido; `terraform.tfvars`
permite ajustes locales sin versionarlos.

### `main.tf`: imagen

```hcl
data "openstack_images_image_v2" "ubuntu" {
  name        = var.image_name
  most_recent = true
}
```

Busca la imagen más reciente que coincida con el nombre. Terraform no la crea
ni la elimina.

### `main.tf`: keypair

```hcl
resource "openstack_compute_keypair_v2" "instance" {
  name       = "${var.instance_name}-key"
  public_key = file(pathexpand(var.ssh_public_key_path))
}
```

Lee la clave pública local y la registra en OpenStack. La clave privada nunca
se transmite.

### `main.tf`: instancia

```hcl
resource "openstack_compute_instance_v2" "instance" {
  name            = var.instance_name
  flavor_name     = var.flavor_name
  image_id        = data.openstack_images_image_v2.ubuntu.id
  key_pair        = openstack_compute_keypair_v2.instance.name
  security_groups = ["default"]
  user_data       = file("${path.module}/cloud-init.yaml.tftpl")

  network {
    uuid = var.public_network_id
  }
}
```

Las referencias permiten que Terraform deduzca el orden. `path.module` hace
estable la ruta de cloud-init independientemente del directorio de ejecución.

### `outputs.tf` y `terraform.tfvars.example`

Los outputs exponen ID, nombre, IPv4 y comando SSH. El ejemplo de variables es
versionable y no contiene secretos; cada operador mantiene una copia local
ignorada por Git.

## Guía técnica de cloud-init

`terraform/cloud-init.yaml.tftpl` comienza con `#cloud-config`, que identifica
su formato YAML. Aunque conserva la extensión `.tftpl`, actualmente se carga
con `file` y no contiene interpolaciones.

### Etapas

Cloud-init atraviesa `cloud-init-local`, `cloud-init`, `cloud-config` y
`cloud-final`. OpenStack puede marcar la VM `ACTIVE` antes de que la última
etapa termine.

### `write_files`

Crea como `root:root`, con permisos `0644`:

```text
/etc/ssh/sshd_config.d/99-loresuelvo-hardening.conf
```

Las directivas aplicadas son:

- `PubkeyAuthentication yes`: permite claves públicas.
- `PasswordAuthentication no`: rechaza contraseñas.
- `KbdInteractiveAuthentication no`: rechaza desafíos interactivos.
- `PermitRootLogin no`: impide login SSH directo de root.
- `AllowUsers ubuntu`: limita SSH al usuario inicial.

La administración posterior se realiza con `sudo`.

### `runcmd`

Las órdenes finales se ejecutan como root:

1. Crean `/run/sshd` para la validación temprana.
2. Ejecutan `/usr/sbin/sshd -t`.
3. Definen entrada UFW denegada por defecto.
4. Permiten tráfico saliente.
5. Permiten TCP 22 como única entrada.
6. Activan UFW sin interacción.

### Diagnóstico

Dentro de la VM:

```bash
cloud-init status --long
sudo cat /var/log/cloud-init-output.log
sudo journalctl -u cloud-init-local -u cloud-init -u cloud-config -u cloud-final
sudo ufw status verbose
sudo sshd -T
```

Sin acceso SSH:

```bash
openstack console log show ID_DE_INSTANCIA
```

### Reejecución y reemplazo

Cloud-init está orientado al primer arranque. Editar el archivo local no
reconfigura una VM existente. Un cambio en `user_data` aparece como `-/+` en el
plan: Terraform destruye la instancia y crea otra.

### Limitaciones y mejoras futuras

- El puerto 22 es visible desde cualquier IP.
- El acceso depende de custodiar correctamente la clave privada.
- UFW es la barrera efectiva porque `default` es permisivo.
- La consola y el modo rescue de OVH siguen siendo vías administrativas.
- Puede limitarse SSH a un CIDR `/32` y agregarse un security group dedicado.
- Pueden incorporarse auditoría, alertas y rotación de claves.
- Los puertos 80/443 deben abrirse explícitamente solo cuando haya un servicio
  web que los necesite.
