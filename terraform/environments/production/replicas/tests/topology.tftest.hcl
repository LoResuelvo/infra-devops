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
    replicas = {
      "production-replica-fixture" = {}
    }
  }

  assert {
    condition     = can(yamldecode(module.replica["production-replica-fixture"].user_data))
    error_message = "Rendered cloud-init must be valid YAML."
  }

  assert {
    condition     = contains(yamldecode(module.replica["production-replica-fixture"].user_data).packages, "python3")
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
      ] : strcontains(module.replica["production-replica-fixture"].user_data, expected)
    ])
    error_message = "Rendered cloud-init must contain only the minimum access bootstrap."
  }

  assert {
    condition = alltrue([
      for forbidden in ["docker", "deploy", "/opt/loresuelvo"] :
      !strcontains(lower(module.replica["production-replica-fixture"].user_data), forbidden)
    ])
    error_message = "Cloud-init must leave Docker, deploy, and application directories to Ansible."
  }
}

run "zero_replicas_by_default" {
  command = plan

  assert {
    condition     = length(output.replicas) == 0
    error_message = "The default replicas map must not create instances."
  }

  assert {
    condition     = output.deployment_hosts == [{ role = "primary", name = "production-primary-fixture", ipv4 = "192.0.2.20" }]
    error_message = "The primary VM must remain a reference-only inventory entry."
  }
}

run "stable_multiple_replicas" {
  command = plan

  variables {
    replicas = {
      "production-replica-02" = {}
      "production-replica-01" = {}
    }
  }

  assert {
    condition     = sort(keys(output.replicas)) == tolist(["production-replica-01", "production-replica-02"])
    error_message = "Replica identities must come from stable map keys."
  }

  assert {
    condition     = tolist([for host in output.deployment_hosts : host.name]) == tolist(["production-primary-fixture", "production-replica-01", "production-replica-02"])
    error_message = "Deployment inventory must contain the primary followed by sorted replicas."
  }

  assert {
    condition     = alltrue([for name, replica in output.replicas : replica.name == name])
    error_message = "Every replica output must preserve its stable name."
  }
}
