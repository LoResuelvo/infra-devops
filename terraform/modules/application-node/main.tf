data "openstack_images_image_v2" "ubuntu" {
  name        = var.image_name
  most_recent = true
}

resource "openstack_compute_keypair_v2" "instance" {
  name       = "${var.instance_name}-key"
  public_key = var.operator_ssh_public_key
  region     = var.region
}

resource "openstack_compute_instance_v2" "instance" {
  name            = var.instance_name
  region          = var.region
  flavor_name     = var.flavor_name
  image_id        = data.openstack_images_image_v2.ubuntu.id
  key_pair        = openstack_compute_keypair_v2.instance.name
  security_groups = ["default"]

  user_data = file("${path.module}/../../../cloud-init/application-node.yaml")

  network {
    uuid = var.public_network_id
  }

  lifecycle {
    # The image catalog moves as OVH publishes Ubuntu updates. Existing nodes
    # stay on the image with which they were created; only new instances use
    # the current most-recent image.
    ignore_changes = [image_id]
  }
}
