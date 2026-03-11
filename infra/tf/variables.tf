# Proxmox provider/static environment values.
variable "proxmox_endpoint" {
  type = string
}
variable "proxmox_api_token" {
  type      = string
  sensitive = true
}
variable "proxmox_insecure" {
  type    = bool
  default = true
}
variable "node_name" {
  type = string
}
variable "datastore_id" {
  type = string
}

# One map entry per VM clone.
variable "vms" {
  type = map(object({
    template_vm_id = number
    vm_id          = number
    vm_name        = string
    bridge         = optional(string)
    bridges        = optional(list(string), [])
    ipv4_address   = string
    ipv4_prefix    = number
    ipv4_gateway   = string
    dns_server     = string
    admin_username = optional(string, "Administrator")
    admin_password = string
    tags           = optional(list(string))
  }))

  validation {
    condition = alltrue([
      for vm in values(var.vms) : try(vm.bridge != "", false) || try(length(vm.bridges) > 0, false)
    ])
    error_message = "Each VM entry must define either `bridge` or at least one entry in `bridges`."
  }
}
variable "tags" {
  type    = list(string)
  default = ["terraform"]
}