# Guía de usuario de Terraform

Esta guía describe la operación diaria de la infraestructura efímera del
equipo. Los comandos se ejecutan desde la raíz del repositorio con Bash.

## Accesos y herramientas

El operador necesita acceso autorizado al proyecto OVHcloud Public Cloud del
equipo, el OpenRC del usuario OpenStack, su contraseña almacenada localmente,
la clave privada SSH correspondiente, Terraform 1.6 o posterior y la CLI de
OpenStack. No es necesario crear otra cuenta o proyecto OVHcloud.

## Preparación local

### OpenRC y contraseña

El OpenRC utilizado por el equipo se guarda fuera del repositorio:

```text
~/.config/loresuelvo/openstack/openrc.sh
```

El archivo local `.env` contiene:

```bash
OS_PASSWORD='<contraseña-openstack>'
```

Ambos archivos están ignorados por Git. No se deben copiar al repositorio,
documentación, tickets ni mensajes.

### Variables Terraform

Crear la configuración local desde el ejemplo:

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Revisar especialmente la ruta absoluta de la clave pública:

```hcl
ssh_public_key_path = "/home/usuario/.ssh/loresuelvo_terraform.pub"
```

Terraform lee únicamente la clave pública. La clave privada permanece en el
equipo del operador.

## Iniciar una sesión OpenStack

Las credenciales deben cargarse en cada terminal nueva:

```bash
source .env
source ~/.config/loresuelvo/openstack/openrc.sh <<< "$OS_PASSWORD"
```

Comprobar la autenticación:

```bash
openstack token issue
```

Si Terraform informa que falta `auth_url` o `cloud`, el OpenRC no fue cargado
en la sesión actual.

## Inicializar y validar

La primera vez, o después de cambiar los proveedores:

```bash
terraform -chdir=terraform init
terraform -chdir=terraform fmt -check
terraform -chdir=terraform validate
```

## Crear una instancia

Generar y revisar el plan:

```bash
terraform -chdir=terraform plan -out=tfplan
terraform -chdir=terraform show tfplan
```

Antes de continuar, comprobar:

- Nombre, región, flavor e imagen.
- Cantidad de altas, cambios y bajas.
- Ausencia de las instancias fijas de test y producción.
- Ausencia de reemplazos o destrucciones inesperadas.

Aplicar exactamente el plan revisado:

```bash
terraform -chdir=terraform apply tfplan
```

Consultar los resultados:

```bash
terraform -chdir=terraform output
terraform -chdir=terraform output -raw ssh_command
```

## Conectarse y verificar

Cloud-init puede tardar algunos segundos después de que OpenStack marque la
instancia como `ACTIVE`:

```bash
ssh -i ~/.ssh/loresuelvo_terraform ubuntu@IP_PUBLICA
```

Dentro de la instancia:

```bash
cloud-init status --wait
sudo ufw status verbose
sudo sshd -T | grep -E '^(port|passwordauthentication|kbdinteractiveauthentication|permitrootlogin|pubkeyauthentication|allowusers) '
```

El resultado esperado es cloud-init en `done`, UFW activo con entrada denegada
por defecto y solo `22/tcp` permitido, autenticación por clave habilitada,
contraseñas y root deshabilitados, y `AllowUsers ubuntu`.

## Destruir y detener la facturación

Generar y revisar un plan específico de destrucción:

```bash
terraform -chdir=terraform plan -destroy -out=destroy.tfplan
terraform -chdir=terraform show destroy.tfplan
```

El plan esperado elimina únicamente la instancia efímera y su keypair:

```bash
terraform -chdir=terraform apply destroy.tfplan
```

Confirmar la eliminación:

```bash
terraform -chdir=terraform state list
openstack server list --name loresuelvo-iac-test
```

Una instancia apagada puede continuar facturándose; hay que destruir el
recurso.

## Secuencia completa de referencia

```bash
source .env
source ~/.config/loresuelvo/openstack/openrc.sh <<< "$OS_PASSWORD"

terraform -chdir=terraform init
terraform -chdir=terraform fmt -check
terraform -chdir=terraform validate
terraform -chdir=terraform plan -out=tfplan
terraform -chdir=terraform show tfplan
terraform -chdir=terraform apply tfplan

# Realizar las pruebas.

terraform -chdir=terraform plan -destroy -out=destroy.tfplan
terraform -chdir=terraform show destroy.tfplan
terraform -chdir=terraform apply destroy.tfplan
```

## Problemas frecuentes

### Falta `auth_url` o `cloud`

El OpenRC no está cargado. Repetir “Iniciar una sesión OpenStack”.

### Error `401`

Comprobar la contraseña local y descargar un OpenRC actualizado para el mismo
usuario y proyecto si fuera necesario.

### Error `409 OverQuota` de security groups

El proyecto no dispone de cuota para crear grupos o reglas adicionales. La
configuración actual reutiliza `default` y filtra dentro de Ubuntu con UFW.

### La VM está activa pero SSH no responde

Esperar a que cloud-init termine. Si continúa inaccesible, consultar la consola:

```bash
openstack console log show ID_DE_INSTANCIA
```

### Terraform propone reemplazar la instancia

Cambios en `user_data`, imagen u otros atributos inmutables requieren destruir
y recrear la VM. Revisar el plan antes de aceptarlo.

## Archivos que nunca deben agregarse a Git

```text
.env
*openrc*
terraform/terraform.tfvars
*.tfstate
*.tfstate.*
*.tfplan
.terraform/
```

Ante una duda:

```bash
git status --short --ignored
git check-ignore -v RUTA_DEL_ARCHIVO
```
