module "replica" {
  for_each = local.replicas

  source = "../../../modules/application-node"

  instance_name           = each.key
  region                  = var.region
  image_name              = var.image_name
  flavor_name             = var.flavor_name
  public_network_id       = var.public_network_id
  operator_ssh_public_key = var.operator_ssh_public_key
}

locals {
  replicas = {
    for index in range(var.replica_count) :
    format("production-replica-%02d", index + 1) => {}
  }

  replica_inventory = {
    for name, replica in module.replica : name => {
      id   = replica.id
      name = replica.name
      ipv4 = replica.ipv4
    }
  }
}
