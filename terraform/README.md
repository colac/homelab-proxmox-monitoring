# Terraform — monitoring VM

Clones the core repo's Packer template into a single `monitoring` VM, using
the core repo's `base-vm` module pinned to a release tag, and generates the
Ansible inventory fragment for it. The Elastic Stack that runs *on* the VM
(single-node Elasticsearch, Kibana, Fleet Server, exporters) is Ansible's job —
see [../RUNBOOK.md](../RUNBOOK.md) for the end-to-end runbook.

One VM is the whole point. The six-VM version of this stack lives in
`homelab-proxmox-elastic`; that topology is more than the 32 GB mini-PC has
spare alongside Nextcloud. If a change here needs a second VM, it belongs in
that repo.

> **The template must carry the Elasticsearch prerequisites.**
> Elasticsearch runs a hard bootstrap check on `vm.max_map_count` and refuses
> to start below 262144. That setting, the memlock/nofile limits and
> `/opt/elastic` are baked into the core repo's Packer templates — a VM cloned
> from an older image fails the `elastic_preflight` role's assert with exactly
> this explanation.

## Sizing

8 GB and 4 vCPU, which is the practical floor for a responsive single node:
Elasticsearch takes a 2 GB heap (3–4 GB resident once JVM overhead is counted),
Kibana around 1 GB, and the agent plus exporters a few hundred more.

`es_heap_size` in `ansible/inventory/group_vars/monitoring.yml` must stay at or
below half of `memory_mb`. Raise both together, never just the heap.

The 100 GB data disk (`data_disk_size`) holds the Elasticsearch data, so it is
the retention ceiling. There is no ILM delete phase configured yet — see
[../TODO.md](../TODO.md).

## Workspace

Terraform Cloud org `colac_homelab`, workspace **`Monitoring`**, **Local**
execution mode — same as every project in the homelab, because Proxmox is
LAN-only and HCP's runners cannot reach it. Create the workspace in the app first; `init`
does not create it for you.

## What it generates

`terraform apply` writes `ansible/inventory/monitoring.yml`. That path is
git-ignored: it holds whatever DHCP address the guest agent reported, which is
machine state rather than source.

`ansible/inventory/` is a **directory** inventory, so this fragment merges with
the hand-authored `hosts.yml` (the agent targets other repos own) instead of
replacing it — each writer owns one file. `inventory/group_vars/` is
hand-authored and is never written from here.

The fragment puts the single host into **three groups at once** —
`monitoring`, `elasticsearch` and `kibana` — because it genuinely plays all
three roles. Keeping those group names identical to the six-VM cluster's is
what let its Ansible roles port across with their `groups['elasticsearch'][0]`
lookups intact.

The inventory host is called `monitoring-vm`, not `monitoring`: Ansible warns
and resolves ambiguously when a host and a group share a name.

## Run it

```bash
mise run tf:plan          # init + plan; credentials for this command only
mise run tf:apply
mise run tf output vm_ip  # any other terraform command, with credentials
```

No `terraform.tfvars` is needed: `.mise/sops-exec terraform` supplies
`TF_VAR_pm_api_*` from `secrets.yaml`. `terraform.tfvars.example` documents
the non-secret overrides only.

If `terraform apply` prints the `guest_agent_reported_an_ip` check warning, the
VM had not finished booting when the guest agent was queried. Wait for it to
come up and re-run `apply` — the inventory is regenerated with the real
address.

<!-- The generated table shows the git:: module source as a bare URL. -->
<!-- markdownlint-disable MD034 -->
<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | ~> 1.15.7 |
| <a name="requirement_local"></a> [local](#requirement\_local) | ~> 2.5 |
| <a name="requirement_proxmox"></a> [proxmox](#requirement\_proxmox) | 3.0.2-rc07 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_local"></a> [local](#provider\_local) | 2.9.0 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_monitoring"></a> [monitoring](#module\_monitoring) | git::https://github.com/colac/homelab-proxmox.git//terraform/modules/base-vm | v2.0.0 |

## Resources

| Name | Type |
|------|------|
| [local_file.ansible_inventory](https://registry.terraform.io/providers/hashicorp/local/latest/docs/resources/file) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_ansible_inventory_hostname"></a> [ansible\_inventory\_hostname](#input\_ansible\_inventory\_hostname) | Host name used inside the generated Ansible inventory. Deliberately different from vm\_name: Ansible warns and behaves ambiguously when a host and a group share a name, and the group is called `monitoring`. Same reason nextcloud's inventory host is `nextcloud-vm`. | `string` | `"monitoring-vm"` | no |
| <a name="input_ansible_inventory_path"></a> [ansible\_inventory\_path](#input\_ansible\_inventory\_path) | Where to write the generated Ansible inventory fragment. Relative to this project directory. | `string` | `"../ansible/inventory/monitoring.yml"` | no |
| <a name="input_cpu_cores"></a> [cpu\_cores](#input\_cpu\_cores) | Number of vCPUs. Elasticsearch and Kibana are both JVM/Node services that want real cores; 4 is the practical floor for a responsive single node. | `number` | `4` | no |
| <a name="input_data_disk_size"></a> [data\_disk\_size](#input\_data\_disk\_size) | Docker data disk, mounted at /var/lib/docker. Holds the Elasticsearch esdata volume, so this is the ILM retention ceiling. | `string` | `"100G"` | no |
| <a name="input_disk0_size"></a> [disk0\_size](#input\_disk0\_size) | OS disk size. Only the OS and /opt/elastic's compose files live here, so it does not need to be large. Must be >= the Packer template's disk — Telmate cannot shrink a cloned disk. | `string` | `"24G"` | no |
| <a name="input_memory_mb"></a> [memory\_mb](#input\_memory\_mb) | Memory in MB. Elasticsearch takes a 2 GB heap (roughly 3-4 GB resident once JVM overhead is counted), Kibana around 1 GB, and the agent plus exporters a few hundred more. 8 GB leaves real headroom on a 32 GB host that also runs Nextcloud. | `number` | `8192` | no |
| <a name="input_network_bridge"></a> [network\_bridge](#input\_network\_bridge) | Proxmox network bridge to attach the VM to. | `string` | `"vmbr0"` | no |
| <a name="input_pm_api_token_id"></a> [pm\_api\_token\_id](#input\_pm\_api\_token\_id) | This is an API token you have previously created for a specific user. | `string` | n/a | yes |
| <a name="input_pm_api_token_secret"></a> [pm\_api\_token\_secret](#input\_pm\_api\_token\_secret) | This uuid is only available when the token was initially created. | `string` | n/a | yes |
| <a name="input_pm_api_url"></a> [pm\_api\_url](#input\_pm\_api\_url) | This is the target Proxmox API endpoint. | `string` | n/a | yes |
| <a name="input_pm_tls_insecure"></a> [pm\_tls\_insecure](#input\_pm\_tls\_insecure) | Skip TLS verification against the Proxmox API. Set via TF\_VAR\_pm\_tls\_insecure by .mise/sops-exec (PROXMOX\_TLS\_INSECURE in mise.toml); true is only needed when the endpoint serves a self-signed certificate. | `bool` | `false` | no |
| <a name="input_proxmox_node"></a> [proxmox\_node](#input\_proxmox\_node) | Proxmox node to deploy the VM on. | `string` | `"pve"` | no |
| <a name="input_proxmox_pool"></a> [proxmox\_pool](#input\_proxmox\_pool) | Optional Proxmox resource pool. | `string` | `null` | no |
| <a name="input_proxmox_storage"></a> [proxmox\_storage](#input\_proxmox\_storage) | Proxmox storage pool for the VM disk and cloud-init drive. | `string` | `"local-lvm"` | no |
| <a name="input_ssh_public_key"></a> [ssh\_public\_key](#input\_ssh\_public\_key) | Path to the SSH public key authorized on the VM. | `string` | `"~/.ssh/homelab-proxmox.pub"` | no |
| <a name="input_template_name"></a> [template\_name](#input\_template\_name) | Name of the Proxmox template to clone. | `string` | `"ubuntu-26.04-template"` | no |
| <a name="input_vm_name"></a> [vm\_name](#input\_vm\_name) | Name of the monitoring VM. | `string` | `"monitoring"` | no |
| <a name="input_vm_user"></a> [vm\_user](#input\_vm\_user) | Cloud-init username created on the VM. | `string` | `"ubuntu"` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_ansible_inventory_file"></a> [ansible\_inventory\_file](#output\_ansible\_inventory\_file) | Generated Ansible inventory fragment for this project. |
| <a name="output_kibana_url"></a> [kibana\_url](#output\_kibana\_url) | Kibana by IP once the Ansible playbooks have run (port 443). Browse to kibana\_fqdn from ansible/inventory/group\_vars/monitoring.yml instead: its Let's Encrypt certificate names that host, not this IP, so the IP URL warns. PiHole must resolve kibana\_fqdn to vm\_ip. |
| <a name="output_vm_ip"></a> [vm\_ip](#output\_vm\_ip) | IP assigned to the deployed monitoring VM. |
| <a name="output_vm_name"></a> [vm\_name](#output\_vm\_name) | Name of the deployed monitoring VM. |
<!-- END_TF_DOCS -->

## Next

```bash
cd ../../../ansible
cd ../../../ansible && ansible-playbook playbooks/site.yml
```
