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
  description = <<-EOT
    Default libvirt pool for machines that do not name one themselves. Every
    pool listed here must appear in `libvirt_pools` in the Ansible group_vars —
    Ansible creates them, Terraform only ever refers to them by name.
  EOT
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
    # Which pool the disk lands in; omitted means `storage_pool`. Like `disk_gb`
    # this is destructive to change — libvirt_volume has no update path in the
    # provider, so moving a machine between pools recreates its disk empty.
    # Decide placement before the machine exists.
    pool = optional(string)
  }))

  # Sized against a 79 GB root filesystem on the host. Disks are thin, so this
  # is a ceiling rather than an upfront cost — but the ceiling still has to fit,
  # because a guest filling its disk fills the hypervisor's root along with it.
  default = {
    forgejo = {
      ip        = "10.42.0.10"
      vcpu      = 2
      memory_mb = 4096
      disk_gb   = 25
    }

    # Forgejo Actions runner. It gets a machine of its own rather than a slot on
    # the Forgejo VM because it executes whatever is in a repository's workflow
    # file: `act_runner` needs the docker socket, which is root on the box it
    # runs on, and that must not be the box holding the git data and the
    # database behind it.
    #
    # vcpu is deliberately above forgejo's — threads overcommit and the host has
    # 16, while a build is the one workload here that can use them. Memory does
    # not overcommit, so 4 GB is a real subtraction from the ~26 GB of guest
    # budget; see the host memory note before raising it.
    runner = {
      ip   = "10.42.0.11"
      vcpu = 4
      # The layer cache is what fills this, not the checkouts. Cut from 20 to
      # make room for the k3s nodes on the same pool, which makes `docker
      # system prune` on a timer load-bearing rather than good hygiene: at
      # 10 GB an unpruned cache reaches the ceiling in weeks, not months.
      # Growing it later recreates the disk empty, same as `pool` above.
      memory_mb = 4096
      disk_gb   = 10
    }

    # --- k3s -----------------------------------------------------------------
    # One server and two agents. All three on `homelab` rather than the old
    # spinning disk, which keeps etcd off ~100 IOPS — every etcd write is an
    # fsync, and that is the one k3s component latency actually breaks.
    #
    # The cost is that this fills the root pool: these three plus the machines
    # above come to 66 GB of ceilings against 69 GB of filesystem. Thin
    # provisioning means only a few GB of that is real today, but nothing more
    # fits here without either the 931 GB drive or a second NVMe.
    #
    # Memory is tighter still. With the five machines above this totals ~26.5
    # of 31 GB, leaving the host ~4.5 GB including the per-guest qemu overhead.
    # Each agent can schedule roughly 1.8 GB of pods once kubelet, containerd
    # and the OS have taken their share — plan the workload against that number,
    # not against 2.5.

    k3s-master = {
      ip   = "10.42.0.30"
      vcpu = 2
      # The server is the smallest of the three: it runs the API server, the
      # scheduler and embedded etcd, and hosts no workload. Do not shrink it
      # further — etcd degrades into leader elections under memory pressure,
      # which takes the whole cluster with it.
      memory_mb = 2560
      disk_gb   = 8
    }

    k3s-worker-1 = {
      ip        = "10.42.0.31"
      vcpu      = 2
      memory_mb = 2560
      disk_gb   = 10
    }

    k3s-worker-2 = {
      ip        = "10.42.0.32"
      vcpu      = 2
      memory_mb = 2560
      disk_gb   = 10
    }

    # --- the project's three databases ---------------------------------------
    # One machine each rather than three engines sharing one. They tune the same
    # kernel knobs against each other — Elasticsearch wants swap off and a large
    # `vm.max_map_count`, Postgres wants specific dirty-ratio and hugepage
    # settings — and a single OOM kill would otherwise take all three down at
    # once. Separate guests also mean one can be rebuilt without a maintenance
    # window on the other two.
    #
    # All three sit in `homelab-db`, the 49 GB partition, so that a runaway
    # table cannot fill the filesystem the hypervisor itself boots from. Their
    # ceilings total 30 GB, leaving room for the base image and for one of them
    # to be raised later without repartitioning.
    #
    # Nothing here serves Forgejo. Forgejo keeps its own Postgres on its own VM
    # and stays self-contained — losing the project's databases must not take
    # the git server with it.

    postgres = {
      ip   = "10.42.0.20"
      vcpu = 2
      # The smallest RAM of the three because Postgres leans on the host page
      # cache rather than a private heap; shared_buffers wants roughly a quarter
      # of this, not most of it.
      memory_mb = 3072
      disk_gb   = 8
      pool      = "homelab-db"
    }

    clickhouse = {
      ip   = "10.42.0.21"
      vcpu = 4
      # ClickHouse assumes far more memory than this and will happily plan a
      # query that needs all of it, so `max_memory_usage` has to be capped in
      # config or a single wide GROUP BY takes the machine out. Columnar
      # compression is why 10 GB of disk goes a long way here.
      memory_mb = 4096
      disk_gb   = 10
      pool      = "homelab-db"
    }

    elasticsearch = {
      ip   = "10.42.0.22"
      vcpu = 2
      # Heap gets half of this and the rest stays free for Lucene's mmap'd
      # segments — that split is why the VM needs 4 GB to give the JVM 2.
      memory_mb = 4096
      # The largest disk of the three: the inverted index plus stored source
      # roughly doubles what you feed it, and the flood-stage watermark makes
      # indices read-only at 95% full, so the usable share of this is ~11 GB.
      disk_gb = 12
      pool    = "homelab-db"
    }
  }
}
