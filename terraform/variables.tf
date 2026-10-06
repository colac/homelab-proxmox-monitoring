variable "pm_api_url" {
  type        = string
  description = "This is the target Proxmox API endpoint."
}

variable "pm_api_token_id" {
  type        = string
  description = "This is an API token you have previously created for a specific user."
  sensitive   = true
}

variable "pm_api_token_secret" {
  type        = string
  description = "This uuid is only available when the token was initially created."
  sensitive   = true
}

variable "pm_tls_insecure" {
  type        = bool
  description = "Skip TLS verification against the Proxmox API. Set via TF_VAR_pm_tls_insecure by .mise/sops-exec (PROXMOX_TLS_INSECURE in mise.toml); true is only needed when the endpoint serves a self-signed certificate."
  default     = false
}

variable "proxmox_node" {
  type        = string
  description = "Proxmox node to deploy the VM on."
  default     = "pve"
}

variable "proxmox_pool" {
  type        = string
  description = "Optional Proxmox resource pool."
  default     = null
}

# The 26.04 template, not 24.04: this project's 24G disk0 only makes sense
# against a template that actually builds LVM and sizes its OS disk at 24G.
# Cloning the 32G/60G 24.04 template with disk0_size = "24G" would fail — the
# Telmate provider cannot shrink a cloned disk.
variable "template_name" {
  type        = string
  description = "Name of the Proxmox template to clone."
  default     = "ubuntu-26.04-template"
}

variable "vm_name" {
  type        = string
  description = "Name of the monitoring VM."
  default     = "monitoring"
}

variable "cpu_cores" {
  type        = number
  description = "Number of vCPUs. Elasticsearch and Kibana are both JVM/Node services that want real cores; 4 is the practical floor for a responsive single node."
  default     = 4
}

variable "memory_mb" {
  type        = number
  description = "Memory in MB. Elasticsearch takes a 2 GB heap (roughly 3-4 GB resident once JVM overhead is counted), Kibana around 1 GB, and the agent plus exporters a few hundred more. 8 GB leaves real headroom on a 32 GB host that also runs Nextcloud."
  default     = 8192
}

variable "disk0_size" {
  type        = string
  description = "OS disk size. Only the OS and /opt/elastic's compose files live here, so it does not need to be large. Must be >= the Packer template's disk — Telmate cannot shrink a cloned disk."
  default     = "24G"
}

# The Elasticsearch data directory is the named Docker volume `esdata`
# (roles/elasticsearch/templates/docker-compose.yml.j2), so it lives under
# /var/lib/docker/volumes — on this disk, not on disk0. This is the number that
# caps how much log data the cluster can hold, and what the ILM retention item
# in TODO.md has to be sized against.
variable "data_disk_size" {
  type        = string
  description = "Docker data disk, mounted at /var/lib/docker. Holds the Elasticsearch esdata volume, so this is the ILM retention ceiling."
  default     = "100G"
}

variable "proxmox_storage" {
  type        = string
  description = "Proxmox storage pool for the VM disk and cloud-init drive."
  default     = "local-lvm"
}

variable "network_bridge" {
  type        = string
  description = "Proxmox network bridge to attach the VM to."
  default     = "vmbr0"
}

variable "vm_user" {
  type        = string
  description = "Cloud-init username created on the VM."
  default     = "ubuntu"
}

variable "ssh_public_key" {
  type        = string
  description = "Path to the SSH public key authorized on the VM."
  default     = "~/.ssh/homelab-proxmox.pub"
}

variable "ansible_inventory_path" {
  type        = string
  description = "Where to write the generated Ansible inventory fragment. Relative to this project directory."
  default     = "../ansible/inventory/monitoring.yml"
}

variable "ansible_inventory_hostname" {
  type        = string
  description = "Host name used inside the generated Ansible inventory. Deliberately different from vm_name: Ansible warns and behaves ambiguously when a host and a group share a name, and the group is called `monitoring`. Same reason nextcloud's inventory host is `nextcloud-vm`."
  default     = "monitoring-vm"
}
