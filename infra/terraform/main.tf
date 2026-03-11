locals {
  vm_specs = yamldecode(file("${path.module}/${var.vm_specs_file}"))

  vms = {
    for vm in local.vm_specs.vms : vm.key => vm
  }
}

resource "proxmox_virtual_environment_vm" "clones" {
  for_each  = local.vms
  node_name = var.node_name
  vm_id     = each.value.vm_id
  name      = each.value.vm_name
  started   = true
  tags      = distinct(concat(var.tags, try(each.value.tags, [])))

  pool_id = proxmox_virtual_environment_pool.blue_team.pool_id

  clone {
    vm_id        = each.value.template_vm_id
    full         = true
    retries      = 3
    datastore_id = var.datastore_id
  }

  dynamic "network_device" {
    for_each = each.value.interfaces
    iterator = nic

    content {
      bridge       = nic.value.bridge
      model        = try(nic.value.model, "virtio")
      firewall     = try(nic.value.firewall, null)
      vlan_id      = try(nic.value.vlan_id, null)
      mac_address  = try(nic.value.mac_address, null)
      mtu          = try(nic.value.mtu, null)
      queues       = try(nic.value.queues, null)
      rate_limit   = try(nic.value.rate_limit, null)
      trunks       = try(nic.value.trunks, null)
      disconnected = try(nic.value.disconnected, null)
    }
  }

  initialization {
    datastore_id = var.datastore_id

    dynamic "ip_config" {
      for_each = each.value.interfaces
      iterator = nic

      content {
        ipv4 {
          address = (
          try(nic.value.ipv4_dhcp, false)
            ? "dhcp"
            : "${nic.value.ipv4_address}/${nic.value.ipv4_prefix}"
          )

          gateway = (
            try(nic.value.ipv4_dhcp, false)
              ? null
              : try(nic.value.ipv4_gateway, null)
          )
        }
      }
    }

    dynamic "dns" {
      for_each = try(length(each.value.dns_servers), 0) > 0 ? [1] : []

      content {
        servers = each.value.dns_servers
      }
    }

    user_account {
      username = try(each.value.admin_username, "Administrator")
      password = each.value.admin_password
    }
  }

  lifecycle {
    precondition {
      condition     = length(each.value.interfaces) > 0
      error_message = "Each VM in vm-specs.yaml must define at least one interface."
    }

    precondition {
      condition = alltrue([
        for nic in each.value.interfaces :
        try(nic.ipv4_dhcp, false) || (
          try(nic.ipv4_address != "", false) &&
          try(nic.ipv4_prefix > 0, false)
        )
      ])
      error_message = "Each interface must define either ipv4_dhcp: true or both ipv4_address and ipv4_prefix."
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