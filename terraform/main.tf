# Downloaded once, then used as the read-only backing file for every guest.
# Each VM's own disk is a thin copy-on-write layer on top, so N machines cost
# roughly one image plus whatever they actually write.
resource "libvirt_volume" "base" {
  name   = "debian-13-genericcloud-amd64.qcow2"
  pool   = var.storage_pool
  source = var.base_image_url
  format = "qcow2"
}

resource "libvirt_volume" "root" {
  for_each = var.vms

  name           = "${each.key}-root.qcow2"
  pool           = var.storage_pool
  base_volume_id = libvirt_volume.base.id
  size           = each.value.disk_gb * 1024 * 1024 * 1024
  format         = "qcow2"
}

# cloud-init seed: creates the admin user, drops the SSH key, pins the static IP.
# This is the whole reason the VMs are reachable by Ansible without any manual
# console work after `terraform apply`.
resource "libvirt_cloudinit_disk" "seed" {
  for_each = var.vms

  name = "${each.key}-seed.iso"
  pool = var.storage_pool

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
