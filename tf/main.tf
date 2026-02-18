resource "proxmox_virtual_environment_vm" "clones" {
  for_each  = var.clones
  node_name = each.value.node_name
  vm_id     = each.value.vm_id
  name      = each.value.name
  started   = each.value.started
  tags      = each.value.tags

  pool_id = proxmox_virtual_environment_pool.blue_team.pool_id

  clone {
    vm_id        = each.value.source_vm_id
    full         = true
    retries      = 3
    datastore_id = try(each.value.datastore_id, null)
  }

  dynamic "network_device" {
    for_each = {
      for idx, nic in try(each.value.network_devices, []) :
      idx => nic
    }

    content {
      bridge  = network_device.value.bridge
      vlan_id = try(network_device.value.vlan_id, null)
      model   = try(network_device.value.model, "virtio")
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