terraform {
  required_version = ">= 1.6"

  required_providers {
    # Pinned to the 0.8 line deliberately. 0.9 replaced the whole resource API
    # with a near 1:1 transcription of libvirt's domain XML — devices.disks[],
    # devices.interfaces[], os.type_machine and several hundred more attributes.
    # That is far more verbose for no gain at this scale.
    #
    # The provider is installed from a local plugin mirror rather than fetched
    # at init time, so build it once before the first `terraform init`:
    #
    #   sudo pacman -S --needed go libvirt cdrtools
    #   curl -sSL -o src.tar.gz \
    #     https://codeload.github.com/dmacvicar/terraform-provider-libvirt/tar.gz/refs/tags/v0.8.3
    #   tar xzf src.tar.gz && cd terraform-provider-libvirt-0.8.3
    #   CGO_ENABLED=1 go build -o terraform-provider-libvirt_v0.8.3 .
    #   DEST=~/.terraform.d/plugins/registry.terraform.io/dmacvicar/libvirt/0.8.3/linux_amd64
    #   mkdir -p "$DEST" && install -m 0755 terraform-provider-libvirt_v0.8.3 "$DEST/"
    #
    # init then reports "Installed dmacvicar/libvirt v0.8.3 (unauthenticated)",
    # which is expected for a locally built plugin. Do not run `init -upgrade` —
    # it would move the machine off this build. The AUR package builds the same
    # way but tracks 0.9.x, so it is the wrong version. go can be removed
    # afterwards; the provider is a static drop-in.
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.8.0"
    }
  }
}
