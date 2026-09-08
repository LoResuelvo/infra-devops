mock_provider "openstack" {
  mock_data "openstack_images_image_v2" {
    defaults = {
      id = "fixture-image-id"
    }
  }

  mock_resource "openstack_compute_instance_v2" {
    defaults = {
      id              = "fixture-instance-id"
      access_ip_v4    = "198.51.100.42"
      access_ip_v6    = ""
      all_metadata    = {}
      all_tags        = []
      power_state     = "active"
      security_groups = ["default"]
    }
  }
}

variables {
  environment = "production"
  primary_instance = {
    name = "production-primary-fixture"
    ipv4 = "192.0.2.20"
  }
  region                  = "BHS5"
  image_name              = "Ubuntu 24.04"
  flavor_name             = "d2-4"
  public_network_id       = "00000000-0000-0000-0000-000000000000"
  operator_ssh_public_key = "ssh-ed25519 AAAAoperator fixture"
}

run "rendered_cloud_init_policy" {
  command = plan

  variables {
    replica_count = 1
  }

  assert {
    condition     = can(yamldecode(module.replica["production-replica-01"].user_data))
    error_message = "Rendered cloud-init must be valid YAML."
  }

  assert {
    condition     = contains(yamldecode(module.replica["production-replica-01"].user_data).packages, "python3")
    error_message = "Rendered cloud-init must install Python for Ansible."
  }

  assert {
    condition = alltrue([
      for expected in [
        "sudo",
        "ufw",
        "AllowUsers ubuntu",
        "PasswordAuthentication no",
        "ufw, allow, \"22/tcp\"",
        "/etc/loresuelvo/bootstrap-version",
      ] : strcontains(module.replica["production-replica-01"].user_data, expected)
    ])
    error_message = "Rendered cloud-init must contain only the minimum access bootstrap."
  }

  assert {
    condition = alltrue([
      for forbidden in ["docker", "deploy", "/opt/loresuelvo"] :
      !strcontains(lower(module.replica["production-replica-01"].user_data), forbidden)
    ])
    error_message = "Cloud-init must leave Docker, deploy, and application directories to Ansible."
  }
}

run "zero_replicas_by_default" {
  command = plan

  assert {
    condition     = output.replica_count == 0 && length(output.replica_names) == 0 && length(output.replica_ipv4) == 0
    error_message = "The default replica count must not create instances."
  }

  assert {
    condition     = output.deployment_hosts == [{ role = "primary", name = "production-primary-fixture", ipv4 = "192.0.2.20" }]
    error_message = "The primary VM must remain a reference-only inventory entry."
  }
}

run "two_deterministic_replicas" {
  command = apply

  variables {
    replica_count = 2
  }

  assert {
    condition     = output.replica_names == tolist(["production-replica-01", "production-replica-02"])
    error_message = "Replica names must be deterministic and ordered."
  }

  assert {
    condition     = tolist([for host in output.deployment_hosts : host.name]) == tolist(["production-primary-fixture", "production-replica-01", "production-replica-02"])
    error_message = "Deployment inventory must contain the primary followed by sorted replicas."
  }

  assert {
    condition     = length(module.replica) == 2 && output.deployment_hosts[0].role == "primary"
    error_message = "The primary must remain outside Terraform resources."
  }
}

run "incremental_growth_keeps_existing_replicas" {
  command = plan

  variables {
    replica_count = 3
  }

  assert {
    condition     = output.replica_names == tolist(["production-replica-01", "production-replica-02", "production-replica-03"])
    error_message = "Growing from two to three must append replica-03."
  }

  assert {
    condition     = length(module.replica) == 3
    error_message = "Growing to three must keep the two stable keys and add one."
  }
}
