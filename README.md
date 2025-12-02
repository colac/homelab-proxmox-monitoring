# Terraform for Proxmox

Deploy core infrastructure components on Proxmox homelab server.

Heavily "inspired" in: https://github.com/bcochofel/homelab-proxmox-core/tree/main
## Prerequisites

### Using WSL
Execute on powershell:
```powershell
# Allow connection on port 8181
New-NetFirewallRule -DisplayName "WSL2 Packer HTTP" -Direction Inbound -Protocol TCP -LocalPort 8181 -Action Allow

# Redirect traffic from Windows to WSL2 container (get WSL2/container IP)
netsh interface portproxy add v4tov4 listenport=8181 listenaddress=0.0.0.0 connectport=8181 connectaddress=CONTAINER_IP

# SSH key used to connect to VM
ssh-keygen -t rsa -b 4096 -C "EMAIL" -f "$HOME/.ssh/id_rsa"
```
### Create Packer User in Proxmox
```bash
# create role and set privileges
pveum role add PackerRole -privs VM.Config.Disk, VM.Config.Cloudinit, SDN.Use, VM.Snapshot, VM.PowerMgmt, Datastore.Allocate, VM.GuestAgent.Unrestricted, VM.Config.Network, VM.Config.CDROM, VM.Console, VM.Backup, VM.Migrate, VM.Config.Options, VM.Clone, VM.GuestAgent.Audit, VM.Snapshot.Rollback, Pool.Audit, VM.Config.CPU, VM.Config.HWType, Datastore.AllocateSpace, Datastore.Audit, VM.Allocate, VM.Config.Memory, VM.Audit

# create user (set <password> to a password of your choice)
pveum user add packer@pve --password Pack3rPr0v1s10n1ng

# set permissions
pveum aclmod / -user packer@pve -role PackerRole

# create API token. Command outputs values needed for authentication
pveum user token add packer@pve packer-automation --privsep 0
```

### Create Terraform User in Proxmox

Login to proxmox web portal and open the console to run the following commands. 
```bash
# create role and set privileges
pveum role add TerraformRole -privs "Datastore.AllocateSpace Datastore.AllocateTemplate Datastore.Audit Pool.Allocate Sys.Audit Sys.Console Sys.Modify VM.Allocate VM.Audit VM.Clone VM.Config.CDROM VM.Config.Cloudinit VM.Config.CPU VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options VM.Migrate VM.PowerMgmt SDN.Use"

# create user (set <password> to a password of your choice)
pveum user add terraform@pve --password IsThisSecure?WasIn1990

# set permissions
pveum aclmod / -user terraform@pve -role TerraformRole

# create API token
# this command outputs values needed for authentication
pveum user token add terraform@pve terraform-automation --privsep 0
```
