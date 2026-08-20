locals {
  # Which pool each machine's disk belongs in. `pool` is optional, so a machine
  # that names none falls back to the default.
  vm_pool = { for name, cfg in var.vms : name => coalesce(cfg.pool, var.storage_pool) }
}

# The read-only backing file every guest's disk is layered on. Each VM's own
# disk is a thin copy-on-write layer over it, so N machines cost roughly one
# image plus whatever they actually write.
#
# One copy per pool in use, rather than one shared copy plus cross-pool backing
# references. The duplicate costs ~3 GB on a volume sized in hundreds, and it
# keeps each pool self-contained: no guest depends on a file in a filesystem
# that might not be mounted.
resource "libvirt_volume" "base" {
  for_each = toset(values(local.vm_pool))

  name   = "debian-13-genericcloud-amd64.qcow2"
  pool   = each.key
  source = var.base_image_url
  format = "qcow2"
}

# `base` gained a for_each above. Without this, Terraform would read the old
# un-keyed address as deleted and destroy the image the running Forgejo disk is
# layered on, taking the machine with it. The key is the literal default pool
# name because moved blocks cannot reference variables.
moved {
  from = libvirt_volume.base
  to   = libvirt_volume.base["homelab"]
}

resource "libvirt_volume" "root" {
  for_each = var.vms

  name           = "${each.key}-root.qcow2"
  pool           = local.vm_pool[each.key]
  base_volume_id = libvirt_volume.base[local.vm_pool[each.key]].id
  size           = each.value.disk_gb * 1024 * 1024 * 1024
  format         = "qcow2"
}

# cloud-init seed: creates the admin user, drops the SSH key, pins the static IP.
# This is the whole reason the VMs are reachable by Ansible without any manual
# console work after `terraform apply`.
resource "libvirt_cloudinit_disk" "seed" {
  for_each = var.vms

  name = "${each.key}-seed.iso"
  pool = local.vm_pool[each.key]

  user_data = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    hostname       = each.key
    search_domain  = var.search_domain
    admin_user     = var.admin_user
    ssh_public_key = var.ssh_public_key
  })

  network_config = templatefile("${path.module}/templates/network-config.yaml.tftpl", {
    ip            = each.value.ip
    prefix        = var.network_cidr_prefix
    gateway       = var.network_gateway
    dns           = var.network_dns
    search_domain = var.search_domain
  })
}

resource "libvirt_domain" "vm" {
  for_each = var.vms

  name      = each.key
  vcpu      = each.value.vcpu
  memory    = each.value.memory_mb
  autostart = true
  cloudinit = libvirt_cloudinit_disk.seed[each.key].id

  # Without host-passthrough the guest gets a conservative emulated CPU and
  # loses a noticeable chunk of performance. Safe here — we never live-migrate.
  cpu {
    mode = "host-passthrough"
  }

  disk {
    volume_id = libvirt_volume.root[each.key].id
  }

  network_interface {
    network_name = var.libvirt_network

    # DHCP is off on this network; addressing comes from cloud-init above.
    # Waiting for a lease that will never arrive would hang `apply`.
    wait_for_lease = false
  }

  # Serial console, so `virsh console <vm>` works when networking is broken.
  console {
    type        = "pty"
    target_type = "serial"
    target_port = "0"
  }

  graphics {
    type        = "spice"
    listen_type = "address"
    autoport    = true
  }

  lifecycle {
    # The seed ISO is only read on first boot. Letting a cosmetic change to it
    # destroy a running server with live data is not a trade worth making.
    ignore_changes = [cloudinit]
  }
}
