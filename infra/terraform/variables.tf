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

variable "vm_specs_file" {
  type    = string
  default = "../../environments/lab01.yaml"
}

variable "tags" {
  type    = list(string)
  default = ["terraform"]
}