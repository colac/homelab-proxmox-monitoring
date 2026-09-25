output "vm_name" {
  value       = module.monitoring.vm_name
  description = "Name of the deployed monitoring VM."
}

output "vm_ip" {
  value       = module.monitoring.vm_ip
  description = "IP assigned to the deployed monitoring VM."
}

output "kibana_url" {
  value       = "https://${module.monitoring.vm_ip}"
  description = "Kibana by IP once the Ansible playbooks have run (port 443). Browse to kibana_fqdn from ansible/inventory/group_vars/monitoring.yml instead: its Let's Encrypt certificate names that host, not this IP, so the IP URL warns. PiHole must resolve kibana_fqdn to vm_ip."
}

output "ansible_inventory_file" {
  value       = local_file.ansible_inventory.filename
  description = "Generated Ansible inventory fragment for this project."
}
