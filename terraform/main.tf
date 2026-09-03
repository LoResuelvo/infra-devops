data "openstack_images_image_v2" "ubuntu" {
  name        = var.image_name
  most_recent = true
}

resource "openstack_compute_keypair_v2" "instance" {
  name       = "${var.instance_name}-key"
  public_key = file(pathexpand(var.ssh_public_key_path))
}

resource "openstack_networking_secgroup_v2" "instance" {
  name        = "${var.instance_name}-sg"
  description = "Restricted SSH access for ${var.instance_name}"
}

resource "openstack_networking_secgroup_rule_v2" "ssh" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = var.ssh_allowed_cidr
  security_group_id = openstack_networking_secgroup_v2.instance.id
}

resource "openstack_compute_instance_v2" "instance" {
  name            = var.instance_name
  flavor_name     = var.flavor_name
  image_id        = data.openstack_images_image_v2.ubuntu.id
  key_pair        = openstack_compute_keypair_v2.instance.name
  security_groups = [openstack_networking_secgroup_v2.instance.name]

  network {
    uuid = var.public_network_id
  }
}
