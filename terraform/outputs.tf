output "vms" {
  description = "Created machines and how to reach them."
  value = {
    for name, cfg in var.vms : name => {
      ip  = cfg.ip
      ssh = "ssh -J ${var.hypervisor_user}@${var.hypervisor_host} ${var.admin_user}@${cfg.ip}"
    }
  }
}

output "ansible_check" {
  description = "Reminder that Ansible expects these same addresses."
  value       = "Addresses must match ansible/inventory/hosts.yml — see README."
}
