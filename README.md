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

Run `make bootstrap` before `make apply` — Terraform expects the pool and
network it creates. Open a new SSH session in between: bootstrap adds you to the
`libvirt` group, and the provider needs a login that already has it.

`make status` reports disk usage and systemd health on every machine.
