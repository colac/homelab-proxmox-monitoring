# Every value here arrives as a TF_VAR_* environment variable from
# .mise/sops-exec (`mise run tf …`), which decrypts the repo-root secrets.yaml
# for that one command. No terraform.tfvars is needed, and no token is ever written to
# a file inside the repo.
provider "proxmox" {
  pm_api_url          = var.pm_api_url
  pm_api_token_id     = var.pm_api_token_id
  pm_api_token_secret = var.pm_api_token_secret
  pm_tls_insecure     = var.pm_tls_insecure
}

module "monitoring" {
  # Pinned to a release tag of the core repo — bump deliberately, read the plan.
  source       = "git::https://github.com/colac/homelab-proxmox.git//terraform/modules/base-vm?ref=v2.0.1"
  vm_name      = var.vm_name
  proxmox_node = var.proxmox_node
  proxmox_pool = var.proxmox_pool

  template_name = var.template_name

  cpu_cores = var.cpu_cores
  memory_mb = var.memory_mb

  disk0_size      = var.disk0_size
  data_disk_size  = var.data_disk_size
  proxmox_storage = var.proxmox_storage
  network_bridge  = var.network_bridge

  # Cloud-init
  vm_user        = var.vm_user
  ssh_public_key = file(pathexpand(var.ssh_public_key))
}

# ----------------------------------------------------------------------------
# Generate this project's Ansible inventory fragment.
#
# ansible/inventory/ is a *directory* inventory: every file in it is merged,
# so each Terraform project owns exactly one fragment and never clobbers
# another project's hosts. group_vars/ stays hand-authored and is never
# written from here.
# ----------------------------------------------------------------------------
resource "local_file" "ansible_inventory" {
  content = templatefile("${path.module}/templates/inventory.yml.tftpl", {
    inventory_hostname = var.ansible_inventory_hostname
    proxmox_vm_name    = module.monitoring.vm_name
    vm_ip              = module.monitoring.vm_ip
    vm_user            = var.vm_user
  })
  filename        = "${path.module}/${var.ansible_inventory_path}"
  file_permission = "0640"
}

# The IP comes from the QEMU guest agent, which is not always up on the very
# first apply. An empty address writes an unusable inventory, so surface it as
# a warning here instead of letting Ansible fail later with a confusing
# "Could not resolve hostname".
check "guest_agent_reported_an_ip" {
  assert {
    condition     = try(length(module.monitoring.vm_ip) > 0, false)
    error_message = "The guest agent has not reported an IP yet. Wait for the VM to finish booting, then re-run `terraform apply` to regenerate ansible/inventory/monitoring.yml."
  }
}
