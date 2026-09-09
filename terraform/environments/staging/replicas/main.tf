module "replica" {
  for_each = local.replicas

  source = "../../../modules/application-node"

  instance_name           = each.key
  region                  = local.region
  image_name              = local.image_name
  flavor_name             = local.flavor_name
  public_network_id       = var.public_network_id
  operator_ssh_public_key = var.operator_ssh_public_key
}

locals {
  region      = "BHS5"
  image_name  = "Ubuntu 24.04"
  flavor_name = "d2-4"

  replicas = {
    for index in range(var.replica_count) :
    format("staging-replica-%02d", index + 1) => {}
  }

  replica_inventory = {
    for name, replica in module.replica : name => {
      id   = replica.id
      name = replica.name
      ipv4 = replica.ipv4
    }
  }
}
