variable "proxmox_endpoint" {
    type = string
}
variable "proxmox_api_token" {
    type = string
    sensitive = true
}
variable "proxmox_insecure" {
    type = bool
    default = true
}

# One map entry per clone you want.
variable "clones" {
  type = map(object({
    name           = string
    vm_id          = number
    node_name      = string            # where the clone will live
    source_vm_id   = number            # golden VMID
    started        = optional(bool, true)
    source_node    = optional(string)  # only if golden lives on a different node
    datastore_id   = optional(string)  # target datastore for the clone (optional)
    tags           = optional(list(string), [])
    description    = optional(string, "Managed by Terraform")

    # Optional: define NICs here if you want TF to enforce network config.
    network_devices = optional(list(object({
      bridge  = string
      vlan_id = optional(number)
      model  = optional(string) # e.g. "virtio"
    })), [])
  }))
}
