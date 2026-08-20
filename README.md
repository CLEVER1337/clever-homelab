# clever-homelab

Terraform builds VMs on a bare-metal Debian/KVM host, Ansible configures them.
One guest so far: Forgejo behind Caddy at `git.homelab.lan`.

## Apply

The server needs `sudo` installed and your key in `authorized_keys` first —
`make bootstrap` turns password authentication off.

Fill in `ansible/inventory/hosts.yml` (address, user) and copy
`terraform/terraform.tfvars.example` to `terraform.tfvars`, then:

```bash
make bootstrap    # bare Debian -> KVM hypervisor, pool, network, firewall
make apply        # create the VMs
make configure    # PostgreSQL, Forgejo, Caddy on the guest
```

Run `make bootstrap` before `make apply` — Terraform expects the pools and
network it creates. Open a new SSH session in between: bootstrap adds you to the
`libvirt` group, and the provider needs a login that already has it.

`make status` reports disk usage and systemd health on every machine.

## Second storage volume

Guests are split across two pools, listed in `libvirt_pools` in
`ansible/inventory/group_vars/hypervisors.yml`. `homelab` lives on the host's
root filesystem; `homelab-db` has a partition to itself, so a database growing
into its `disk_gb` ceiling cannot exhaust the space the host itself runs on.

Ansible makes the filesystem and mounts it, but **the partition is created by
hand** — a playbook running `sgdisk` against a variable is one typo away from
rewriting the partition table of a disk that also holds Windows, and this is a
once-per-host job. `make bootstrap` stops with a clear error if it is missing.

Find the free space. This host had a 49.6 GiB gap left between Windows and the
Linux root, so nothing had to be shrunk:

```bash
sudo sgdisk -p /dev/nvme0n1     # partition table, in sectors
sudo sgdisk -F /dev/nvme0n1     # first usable free sector
```

Then, with the gap's first and last sector (here 725506048 and 829550591 —
both already 1 MiB aligned, so nothing needs rounding):

```bash
sudo apt install gdisk
sudo sgdisk --backup=/root/gpt-nvme0n1.bak /dev/nvme0n1   # the disk holds Windows too
sudo sgdisk -n 8:725506048:829550591 -t 8:8300 -c 8:homelab-db /dev/nvme0n1
sudo partprobe /dev/nvme0n1
```

GPT numbers table entries, not disk order, so this becomes `nvme0n1p8` even
though it sits physically between `p4` and `p6`. Put whatever it is called into
the pool's `device:` field, then run `make bootstrap`.
