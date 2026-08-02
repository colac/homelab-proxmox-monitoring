# Ansible — Nextcloud (AIO) + Caddy + Tailscale

Configures a VM (provisioned by Terraform from the Packer base template) to run
**Nextcloud All-in-One**, fronted by a **Caddy** reverse proxy that terminates
TLS for a real domain (Let's Encrypt via Cloudflare DNS-01), reachable
privately over the LAN and, off-LAN, over a **Tailscale subnet route**. See
[../NEXTCLOUD.md](../NEXTCLOUD.md) for the full from-zero runbook and the
"why" behind this design; this doc covers the `ansible/` component on its own.

## Where this fits in the workflow

```text
Packer    ─> base Ubuntu 24.04 template (Docker + Tailscale baked in)
Terraform ─> clones the template into the "nextcloud" VM, prints its IP
Ansible   ─> deploys Nextcloud AIO + Caddy (TLS) + a Tailscale subnet route
             + NAS external storage + extra Nextcloud users  <-- you are here
```

## Prerequisites

- The VM exists (`cd terraform/projects/nextcloud && terraform apply`) and you
  have its IP:

  ```bash
  terraform output ansible_inventory_line
  # e.g. nextcloud ansible_host=192.168.1.43 ansible_user=ubuntu
  ```

- Your SSH public key (the one passed to Terraform as `ssh_public_key`) can log
  in as the `ubuntu` user, and that user has passwordless sudo (the template
  configures this).
- **Tailscale**: MagicDNS enabled in the admin console; optionally an
  **auth key** (Settings → Keys) to join the node non-interactively. The
  subnet-route approval and split-DNS entry are one-time steps done *after*
  the node joins — see step 5.
- **Cloudflare**: the public zone has a scoped API token (Zone → DNS → Edit,
  limited to that zone) for the ACME DNS-01 challenge.
- **PiHole**: a local DNS A record for the Nextcloud hostname → the VM's LAN
  IP (Local DNS → DNS Records).
- **NAS (TrueNAS)**: SMB enabled, a share created, and a dedicated SMB user
  (not `root`/`admin`) with read/write on it. See
  [../TrueNAS/README.md](../TrueNAS/README.md).

## 1. Install Ansible and the required collections

`ansible-core` is already pinned in the repo's top-level `requirements.txt`, so
the project virtualenv has it. From the repo root:

```bash
make install-python-tools          # creates .venv with ansible-core
source .venv/bin/activate
```

Then install the Galaxy collections this playbook needs (`community.docker`,
`ansible.posix` — see `requirements.yml`):

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml
```

> No virtualenv? `pipx install ansible` (or `pip install ansible`) works too —
> just make sure `ansible` and `ansible-galaxy` are on your PATH.

## 2. Create your inventory

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
# edit ansible_host to match the Terraform output
```

`inventory/hosts.yml` is git-ignored so you never commit real addresses.

## 3. Check connectivity

```bash
ansible nextcloud -m ping
```

## 4. Configure secrets and NAS/user vars

```bash
cp vault.yml.example vault.yml
# set: nextcloud_domain, reverse_proxy_acme_email, nextcloud_aio_nas_user,
#   nextcloud_aio_nas_password, nextcloud_aio_users (usernames + passwords),
#   cloudflare_dns_api_token, tailscale_authkey
ansible-vault encrypt vault.yml
# edit group_vars/nextcloud.yml: nextcloud_aio_nas_host, nextcloud_aio_nas_mounts,
#   nextcloud_aio_nas_personal_share
```

## 5. Run the playbook

```bash
ansible-playbook site.yml -e @vault.yml --ask-vault-pass
```

This deploys AIO + Caddy and (if you supplied a Tailscale auth key) joins the
tailnet. NAS mounts and any configured Nextcloud users only apply once the
Nextcloud container is actually running — see the two-pass note below.

After the first run, do the two one-time Tailscale admin steps the playbook
reminds you about:

- **Approve the subnet route** (Machines → the node → Edit route settings) so
  off-LAN devices can reach the VM.
- **Add split-DNS** for your domain pointing at the PiHole (DNS → Nameservers
  → Restrict to domain) so tailnet devices resolve the hostname to the LAN IP.

## 6. Finish Nextcloud setup, then run Ansible again

The AIO **admin interface** is bound to `127.0.0.1:8080` on the VM for safety.
Reach it through an SSH tunnel for first-run setup:

```bash
ssh -L 8080:localhost:8080 ubuntu@<vm-ip>
# browse https://localhost:8080 (accept the self-signed cert) → copy the
# passphrase → set the domain to nextcloud_domain from vault.yml → start
# containers → set the admin password
```

```bash
# Second pass: now that the container is up, apply NAS mounts + users
ansible-playbook site.yml -e @vault.yml --ask-vault-pass
```

Reach Nextcloud at your configured domain — on the LAN directly, or from
anywhere once you're on the tailnet.

> **Why two passes:** the NAS and user-creation tasks need the Nextcloud
> container *running*, which only happens after AIO's first-run setup. Pass 1
> deploys AIO + Caddy; pass 2 attaches storage and creates users. Both tasks
> are idempotent, so re-running is always safe.

## What each role does

- **`tailscale`** — ensures `tailscaled` is running; runs `tailscale up` (if
  an auth key is given) advertising the LAN as a subnet route; keeps the
  route advertised on re-runs. Idempotent.
- **`nextcloud_aio`** — renders `/opt/nextcloud-aio/compose.yaml` and brings up
  the AIO mastercontainer with `docker compose`; the mastercontainer then
  spawns the rest of the AIO stack itself over the Docker socket. When
  `nextcloud_aio_users` is non-empty, creates those Nextcloud accounts (see
  below). When `nextcloud_aio_nas_enabled` is true, attaches the configured
  NAS shares as external storage (see below).
- **`reverse_proxy`** — renders and builds a local Caddy image
  (`nextcloud-caddy:local`) that terminates TLS for `nextcloud_domain` via
  Cloudflare DNS-01 and proxies to AIO's Apache container.

## NAS external storage (SMB)

Nextcloud talks SMB directly to the NAS — no host mount, no extra VM disk. The
`nextcloud_aio` role configures each mount with `occ files_external` inside
the AIO container; each task is idempotent (it skips a mount whose name
already exists) and only runs once the Nextcloud container is up.

> **Create-only, by design.** The idempotency check keys on the mount *name*
> (`/Familia`), so an existing mount is left completely untouched — a changed
> host, share, `applicable_users`, or `readonly` will **not** be applied to it,
> whether it came from `group_vars` or from a user's `nas_folder`. To change an
> existing mount, delete it and let the next run recreate it (deleting detaches
> only; NAS files are not touched):
>
> ```bash
> docker exec --user www-data nextcloud-aio-nextcloud php occ files_external:list
> docker exec --user www-data nextcloud-aio-nextcloud php occ files_external:delete <id> -y
> ```

`nextcloud_aio_nas_mounts` (in `group_vars/nextcloud.yml`) is a list, one
entry per folder to attach — not one global share. Each item:

```yaml
nextcloud_aio_nas_mounts:
  - name: "Familia"                # folder name shown in Nextcloud Files
    share: "media"                 # SMB share name
    subfolder: "Familia"           # optional: path inside the share
    applicable_users: ["admin"]    # optional: restricts from "all users" to this list
    readonly: true                 # optional: read-only for whoever can see it
```

Mounts are visible to **all** Nextcloud users unless `applicable_users` is
set, and `readonly` applies to everyone who can see the mount — **including
`admin`**, who is not exempt. Both settings are per-*mount*, not per-user, so
granting one account read-write and another read-only on the same NAS path
needs two entries with the same `share`/`subfolder` but different
`name`/`applicable_users`/`readonly`.

The live config deliberately avoids that split: `Familia` is one read-only
mount for everyone. Nextcloud is the viewing and sharing surface for the
curated library; files are moved into it over SMB directly against TrueNAS.
That is not a workaround — a move between two Nextcloud mounts is a
copy-and-delete streamed through the VM (`Common::moveFromStorage` only does a
server-side rename within the *same* storage object), whereas the same move on
TrueNAS is an instant rename inside one dataset. Keeping the mount read-only
therefore costs nothing and removes any chance of a stray drag-and-drop in the
web UI or a desktop sync client deleting curated data.

Credentials (`nextcloud_aio_nas_user`/`nextcloud_aio_nas_password`, and any
per-mount `user`/`password` override) live in `vault.yml`, never in
`group_vars`. To disable the integration entirely, set
`nextcloud_aio_nas_enabled: false`.

## Nextcloud users

`nextcloud_aio_users` creates accounts beyond the AIO admin via idempotent
`occ user:add` calls. It lives in **`vault.yml`**, not `group_vars` — usernames
and passwords are kept together and out of the tracked repo:

```yaml
nextcloud_aio_users:
  - name: "alice"
    display_name: "Alice"       # optional, defaults to name
    password: "…"
    nas_folder: true            # optional: private NAS folder, see below
```

The task skips any username that already exists, so re-running is safe.

### Private per-user folders

`nas_folder: true` attaches
`<nextcloud_aio_nas_personal_share>/<username>` as a mount named after the
user, **scoped to that account only** (`applicable_users`). The share is set in
`group_vars/nextcloud.yml`; the subfolder must already exist on the NAS.

This is why personal folders are not listed in `nextcloud_aio_nas_mounts`:
deriving them from the vault user list keeps usernames out of the repo, and
scoping is automatic. A personal folder added as a plain mount would default to
**all users** — every account would see and be able to write to it.

## Why Caddy + Cloudflare DNS-01 + a Tailscale subnet route

- AIO's Apache container binds to `127.0.0.1:11000` (`APACHE_IP_BINDING` +
  `APACHE_PORT`); nothing is exposed on the LAN directly by AIO itself.
- Caddy terminates TLS with a real Let's Encrypt cert (DNS-01 via Cloudflare,
  no inbound ports opened) and proxies to that local port.
- `SKIP_DOMAIN_VALIDATION=true` is set because the domain isn't publicly
  reachable on `:443` (private only), so AIO's built-in public validation
  would otherwise fail.
- Tailscale `serve` is deliberately **not** used (see
  [../CLAUDE.md](../CLAUDE.md)) — it can't present a certificate for a custom
  domain. Instead the VM advertises the LAN as a subnet route, and PiHole
  split-DNS lets tailnet devices resolve the real hostname to the LAN IP.

## Day-2

```bash
# tail the stacks
ssh ubuntu@<vm-ip> 'cd /opt/nextcloud-aio && sudo docker compose ps'
ssh ubuntu@<vm-ip> 'cd /opt/nextcloud-caddy && sudo docker compose ps'
# AIO updates & backups are managed from the admin UI (port 8080 via tunnel)
# Caddy/cert issues:
ssh ubuntu@<vm-ip> 'sudo docker logs nextcloud-caddy'
```
