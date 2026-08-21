.PHONY: help deps bootstrap plan apply configure all destroy ssh lint

ANSIBLE_DIR := ansible
TF_DIR      := terraform

help:
	@echo "make deps       - install Ansible collections"
	@echo "make bootstrap  - bare Debian -> KVM hypervisor"
	@echo "make plan       - preview VM changes"
	@echo "make apply      - create/update VMs"
	@echo "make configure  - install Forgejo on the VM"
	@echo "make all        - bootstrap + apply + configure"
	@echo "make ssh        - shell into a guest, default forgejo (make ssh VM=runner)"
	@echo "make status     - disk usage and systemd health, all machines"
	@echo "make lint       - syntax-check both sides"
	@echo "make destroy    - tear down the VMs (keeps the hypervisor)"

# NOT a prerequisite of anything: Arch's `ansible` package already bundles every
# collection in requirements.yml at a high enough version, so there is nothing to
# fetch. Run this only if your distribution ships them older than that.
deps:
	ansible-galaxy collection install -r $(ANSIBLE_DIR)/requirements.yml

# -K prompts for the sudo password. The hypervisor uses stock Debian sudoers,
# which asks for one; the guests get NOPASSWD from cloud-init and do not.
bootstrap:
	cd $(ANSIBLE_DIR) && ansible-playbook bootstrap.yml -K

# No -upgrade: the provider comes from a local plugin mirror, and -upgrade would
# move this machine off that pinned build. See terraform/versions.tf.
plan:
	cd $(TF_DIR) && terraform init && terraform plan

apply:
	cd $(TF_DIR) && terraform init && terraform apply

configure:
	cd $(ANSIBLE_DIR) && ansible-playbook site.yml

all: bootstrap apply configure

# Which guest to open. Any key of `vms` in terraform/variables.tf — the command
# itself comes from the `vms` output, so a machine added there needs nothing
# here. Naming one that does not exist lists what does.
VM ?= forgejo

ssh:
	@cmd="$$(cd $(TF_DIR) && terraform output -json vms | \
	  python3 -c 'import json,sys; vms=json.load(sys.stdin); vm=vms.get("$(VM)"); \
	  sys.exit("no vm named $(VM) — have: " + ", ".join(sorted(vms))) if vm is None else print(vm["ssh"])')" \
	  && eval "$$cmd"

status:
	@cd $(ANSIBLE_DIR) && ansible all -e ansible_become=false -m ansible.builtin.shell \
	  -a 'echo "$$(df -h --output=pcent,avail,size / | tail -1)  $$(systemctl is-system-running 2>/dev/null)"' \
	  2>/dev/null | grep -vE '^\s*$$'

lint:
	cd $(TF_DIR) && terraform fmt -check -recursive && terraform validate
	cd $(ANSIBLE_DIR) && ansible-playbook --syntax-check bootstrap.yml site.yml

destroy:
	cd $(TF_DIR) && terraform destroy
