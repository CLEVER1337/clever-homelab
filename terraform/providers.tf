# Terraform runs from the laptop and talks to libvirt on the hypervisor over SSH.
# Nothing needs to be installed on the server for this beyond libvirt itself,
# which the Ansible `bootstrap.yml` play puts there.
#
# The SSH user must be in the `libvirt` group on the host (bootstrap does that)
# so that the /system connection works without root.
provider "libvirt" {
  uri = "qemu+ssh://${var.hypervisor_user}@${var.hypervisor_host}/system?sshauth=agent,privkey&keyfile=${var.ssh_private_key_path}"
}
