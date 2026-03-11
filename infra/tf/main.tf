resource "proxmox_virtual_environment_vm" "clones" {
  for_each  = var.vms
  node_name = var.node_name
  vm_id     = each.value.vm_id
  name      = each.value.vm_name
  started   = true
  tags      = try(each.value.tags, var.tags)

  pool_id = proxmox_virtual_environment_pool.blue_team.pool_id

  clone {
    vm_id        = each.value.template_vm_id
    full         = true
    retries      = 3
    datastore_id = var.datastore_id
  }

  dynamic "network_device" {
    for_each = length(try(each.value.bridges, [])) > 0 ? each.value.bridges : [each.value.bridge]

    content {
      bridge = network_device.value
      model  = "virtio"
    }
  }

  initialization {
    datastore_id = var.datastore_id

    ip_config {
      ipv4 {
        address = "${each.value.ipv4_address}/${each.value.ipv4_prefix}"
        gateway = each.value.ipv4_gateway
      }
    }

    dns {
      servers = [each.value.dns_server]
    }

    user_account {
      username = try(each.value.admin_username, "Administrator")
      password = each.value.admin_password
    }
  }
}

resource "proxmox_virtual_environment_pool" "blue_team" {
  pool_id = "tf-blue_team"
  comment = "Terraform-managed blue_team clones"
}

resource "proxmox_virtual_environment_acl" "blue_team_pool_admin" {
  path      = "/pool/${proxmox_virtual_environment_pool.blue_team.pool_id}"
  group_id  = "blue_team"
  role_id   = "PVEVMAdmin"
  propagate = true
}