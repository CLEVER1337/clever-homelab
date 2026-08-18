variable "hypervisor_host" {
  description = "Address of the bare-metal Debian host running libvirt."
  type        = string
}

variable "hypervisor_user" {
  description = "SSH user on the hypervisor. Must be a member of the `libvirt` group."
  type        = string
}

variable "ssh_private_key_path" {
  description = "Private key used to reach the hypervisor."
  type        = string
  default     = "~/.ssh/id_ed25519"
}

variable "ssh_public_key" {
  description = "Public key injected into every VM via cloud-init."
  type        = string
}

variable "admin_user" {
  description = <<-EOT
    Login created inside each VM by cloud-init. Ansible connects as this user,
    so it MUST match `ansible_user` in ansible/inventory/hosts.yml. A mismatch
    is not caught at apply time — the VM just comes up and Ansible cannot log in.
  EOT
  type        = string
  default     = "supervisor"
}

# --- libvirt objects owned by Ansible, referenced here by name ------------------
# These are created by the `libvirt` role in bootstrap.yml. Terraform only
# consumes them, so the two tools never contend over the same resource.

variable "storage_pool" {
  description = "Name of the libvirt storage pool holding VM disks."
  type        = string
  default     = "homelab"
}

variable "libvirt_network" {
  description = "Name of the libvirt NAT network the VMs attach to."
  type        = string
  default     = "homelab"
}

# --- guest image ---------------------------------------------------------------

variable "base_image_url" {
  description = "Debian cloud image downloaded once and used as the CoW backing file."
  type        = string
  default     = "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
}

# --- network layout ------------------------------------------------------------
# Must match `homelab_net_*` in ansible/inventory/group_vars/hypervisors.yml.

variable "network_cidr_prefix" {
  description = "Prefix length of the VM subnet."
  type        = number
  default     = 24
}

variable "network_gateway" {
  description = "Gateway for the VM subnet — the host side of the libvirt bridge."
  type        = string
  default     = "10.42.0.1"
}

variable "network_dns" {
  description = "Resolver handed to guests. Defaults to the libvirt dnsmasq on the gateway."
  type        = list(string)
  default     = ["10.42.0.1"]
}

variable "search_domain" {
  description = "DNS search domain for the guests."
  type        = string
  default     = "homelab.lan"
}

# --- the machines themselves ---------------------------------------------------
# Adding a VM later means adding one entry here. Nothing else changes.

variable "vms" {
  description = "Virtual machines to create, keyed by hostname."
  type = map(object({
    ip        = string
    vcpu      = number
    memory_mb = number
    disk_gb   = number
  }))

  # Sized against a 79 GB root filesystem on the host. Disks are thin, so this
  # is a ceiling rather than an upfront cost — but the ceiling still has to fit,
  # because a guest filling its disk fills the hypervisor's root along with it.
  default = {
    forgejo = {
      ip        = "10.42.0.10"
      vcpu      = 2
      memory_mb = 4096
      disk_gb   = 40
    }
  }
}
