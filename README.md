# clever-homelab

Terraform builds VMs on a bare-metal Debian/KVM host, Ansible configures them.
Guests: Forgejo behind Caddy at `git.homelab.lan`, its Actions runner,
PostgreSQL, ClickHouse, Elasticsearch, and a k3s cluster (one server, two
agents).

## Infrastructure

One bare-metal Debian box runs libvirt/KVM and nothing else — everything else is
a VM built from the Debian cloud image. Labels below read `vCPU / RAM / disk`;
disks are thin, so those are ceilings, not what is allocated today.

```mermaid
flowchart TB
    LAN["LAN"]

    subgraph HOST["bare-metal Debian · libvirt/KVM"]
        subgraph POOL1["pool <b>homelab</b> — host root filesystem"]
            FORGEJO["<b>forgejo-vm</b> · 10.42.0.10<br/>Caddy → Forgejo + its own Postgres<br/>2 / 4G / 25G"]
            RUNNER["<b>runner-vm</b> · 10.42.0.11<br/>Forgejo Actions runner · Docker<br/>4 / 4G / 10G"]

            subgraph K3S["k3s · pods on 10.44.0.0/16"]
                MASTER["<b>k3s-master</b> · .30<br/>server, SQLite, tainted<br/>2 / 2.5G / 8G"]
                W1["<b>k3s-worker-1</b> · .31<br/>2 / 2.5G / 10G"]
                W2["<b>k3s-worker-2</b> · .32<br/>2 / 2.5G / 10G"]
            end
        end

        subgraph POOL2["pool <b>homelab-db</b> — dedicated partition"]
            PG["<b>postgres-vm</b> · .20<br/>2 / 3G / 8G"]
            CH["<b>clickhouse-vm</b> · .21<br/>4 / 4G / 10G"]
            ES["<b>elasticsearch-vm</b> · .22<br/>podman quadlet<br/>2 / 4G / 12G"]
        end
    end

    LAN -->|"80, 443, 2222 · DNAT on the host"| FORGEJO
    LAN -.->|"ssh, then ProxyJump to any guest"| HOST
    MASTER --- W1
    MASTER --- W2
    K3S -.->|"the project's data"| POOL2
```

All guests share one NAT network, `10.42.0.0/24`, with fixed addresses written
by cloud-init — no DHCP, so the Ansible inventory cannot drift. Nothing on it is
routable from the LAN: only Caddy is published outward, and everything else is
reached by jumping through the hypervisor.

The three databases belong to the project and accept connections from the guest
and pod networks only. Forgejo is not among their clients — it keeps its own
Postgres on its own VM, so losing them cannot take the git server with it.

The two tools never touch the same object:

```mermaid
flowchart LR
    ANS1["<b>Ansible</b> · bootstrap.yml"] -->|creates| OBJ["pools · NAT network<br/>firewall · host packages"]
    OBJ -.->|referenced by name| TF["<b>Terraform</b>"]
    TF -->|creates| VMS["the VMs<br/>disks · cloud-init"]
    VMS -.->|inventory| ANS2["<b>Ansible</b> · site.yml"]
    ANS2 -->|configures| SVC["Forgejo · Caddy<br/>databases · k3s"]
```

Adding a machine is one entry in `vms` in `terraform/variables.tf` plus an
address in `ansible/inventory/hosts.yml`; the sizing comments there are worth
reading first, since RAM does not overcommit and the totals are close to the
host's.

## Commands

All wrapped in makefile so you can easily launch it.

| Command | What it does |
| --- | --- |
| `make help` | list the targets |
| `make deps` | install the Ansible collections — only needed if your distro ships them older than `requirements.yml` |
| `make bootstrap` | bare Debian -> KVM hypervisor: pools, network, firewall, clock |
| `make plan` | preview what Terraform would change |
| `make apply` | create/update the VMs |
| `make configure` | run `site.yml`: Forgejo + Caddy, the Actions runner, the databases, k3s |
| `make all` | `bootstrap` + `apply` + `configure` |
| `make status` | disk usage and systemd health on every machine |
| `make ssh` | shell into the Forgejo VM |
| `make lint` | `terraform fmt`/`validate` plus a playbook syntax check |
| `make destroy` | tear down the VMs, keep the hypervisor |

## First run

The server needs `sudo` installed and your key in `authorized_keys` first —
`make bootstrap` turns password authentication off.

Fill in `ansible/inventory/hosts.yml` (address, user) and copy
`terraform/terraform.tfvars.example` to `terraform.tfvars`, then:

```bash
make bootstrap
make apply
make configure
```

Run `make bootstrap` before `make apply` — Terraform expects the pools and
network it creates. Open a new SSH session in between: bootstrap adds you to the
`libvirt` group, and the provider needs a login that already has it.

## CI: the Actions runner

`runner-vm` runs Forgejo Actions jobs, each one in a Docker container on that
guest. It has a machine of its own because a workflow file is code nobody
reviewed, and the runner must hold the docker socket to do its job — which is
root on whatever box it sits on. That box must not be the one holding the git
data.

Registration is offline and needs no clicking: `make configure` generates a
40-character secret on the Forgejo guest (`/etc/forgejo/runner_secret`),
registers it there with `forgejo-cli actions register`, and writes the same
secret on the runner as a systemd credential. Both the command and the whole
role are idempotent, so re-running `make configure` never produces a second
runner. Rebuilding `runner-vm` alone re-uses the existing registration; deleting
that secret file is what creates a new one.

Two details the guests' network forces:

- **No DNS.** libvirt's dnsmasq hands out no leases, so it knows no names. The
  runner gets `git.homelab.lan` in `/etc/hosts`, and job containers get it via
  `--add-host` — they clone from the name in the certificate, not an address.
- **A private CA.** Caddy signs that name itself, so the runner installs
  Caddy's root into its trust store and bind-mounts `/etc/ssl/certs` into every
  job container.

What a workflow may say in `runs-on:` is set by `forgejo_runner_labels` in
`ansible/inventory/group_vars/runners.yml` — `docker`, `ubuntu-latest` and
`debian-trixie` today, all of them images from `data.forgejo.org`. There is
deliberately no `host` label: a job with one would run on the VM itself instead
of in a container.

Two jobs run at once (`forgejo_runner_capacity`), each with a one-hour ceiling.
The layer cache is pruned every Sunday — on a 10 GB disk that timer is
load-bearing, not hygiene.

When a job stays queued, the runner is the place to look:

```bash
ssh -J supervisor@<host> supervisor@10.42.0.11 'journalctl -u forgejo-runner -f'
```

An unreachable instance, a rejected token or an image it cannot pull all leave
the unit `active` and looping — the journal is the only place they show.

## Second storage volume

Made a mistake while shrinking data for linux first time: I shrinked not enough. 
So I've shrinked one more time but unallocated space appeared in front of already setuped 
linux ext4 volume and I decided to devide VMs by two parts you can see below.

Guests are split across two pools, listed in `libvirt_pools` in
`ansible/inventory/group_vars/hypervisors.yml`. `homelab` lives on the host's
root filesystem; `homelab-db` has a partition to itself, so a database growing
into its `disk_gb` ceiling cannot exhaust the space the host itself runs on.

Ansible makes the filesystem and mounts it, but **the partition is created by
hand**, once per host — a playbook running `sgdisk` against a variable is one
typo away from rewriting a partition table. `make bootstrap` stops with a clear
error if the partition is missing.

Find the free space, then cut the partition from it:

```bash
sudo sgdisk -p /dev/<disk>     # partition table, in sectors
sudo sgdisk -F /dev/<disk>     # first usable free sector

sudo sgdisk --backup=/root/gpt-<disk>.bak /dev/<disk>
sudo sgdisk -n <n>:<first>:<last> -t <n>:8300 -c <n>:homelab-db /dev/<disk>
sudo partprobe /dev/<disk>
```

Keep the boundaries 1 MiB aligned (a multiple of 2048 sectors). GPT numbers
table entries, not disk order, so the new partition's name may not follow its
neighbours — put whatever it is actually called into the pool's `device:`
field, then run `make bootstrap`.
