terraform {
  required_version = "~> 1.15.7"

  cloud {
    organization = "colac_homelab"

    workspaces {
      name = "Monitoring"
    }
  }

  required_providers {
    proxmox = {
      source  = "Telmate/proxmox"
      version = "3.0.2-rc07"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}
