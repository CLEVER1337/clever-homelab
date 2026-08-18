terraform {
  required_version = ">= 1.6"

  required_providers {
    # Pinned to the 0.8 line deliberately. 0.9 replaced the whole resource API
    # with a near 1:1 transcription of libvirt's domain XML — devices.disks[],
    # devices.interfaces[], os.type_machine and several hundred more attributes.
    # That is far more verbose for no gain at this scale.
    #
    # The provider is installed from a local plugin mirror rather than fetched
    # at init time; build it once before the first `terraform init`.
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.8.0"
    }
  }
}
