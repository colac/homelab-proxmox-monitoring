# Homelab Proxmox

Infrastructure-as-code for a single-node **Proxmox VE** homelab. One hardened
base image, one reusable VM module, one configuration playbook — built as a
**Packer → Terraform → Ansible** pipeline.

Heavily "inspired" by
<https://github.com/bcochofel/homelab-proxmox-core/tree/main>.

- **New here?** Read the strategy and architecture below.
- **Want to deploy something?** [NEXTCLOUD.md](NEXTCLOUD.md) is the complete
  from-zero runbook for the flagship deployment.
- **Working on one component?** Each folder has its own README — see
  [Repository map](#repository-map).

## Deployment strategy

Three stages, each owning exactly one thing. The split is deliberate: a stage
can be re-run without redoing the others, and each produces an artifact the
next one consumes.

```text
┌──────────┐  bakes    ┌─────────────────────┐
│  Packer  │──────────▶│ ubuntu-24.04-       │  Proxmox VM template:
│          │           │ template            │  hardened Ubuntu 24.04 LTS,
└──────────┘           └─────────────────────┘  Docker + Tailscale, sealed
                                  │
┌───────────┐  clones             ▼
│ Terraform │──────────▶┌─────────────────────┐  VM sized per project,
│           │           │ VM (e.g. nextcloud) │  cloud-init user + SSH key,
└───────────┘           └─────────────────────┘  IP printed as output
                                  │
┌──────────┐  configures          ▼
│ Ansible  │──────────▶┌─────────────────────┐  Apps, TLS, storage mounts,
│          │           │ running services    │  users — everything mutable
└──────────┘           └─────────────────────┘
```

| Stage | Owns | Re-run when |
|---|---|---|
| **Packer** | The golden image: OS, hardening, Docker, Tailscale binaries | The base OS or baked-in tooling changes (rare) |
| **Terraform** | VM existence and shape: CPU/RAM/disk, network, cloud-init user | You resize, add, or destroy a VM |
| **Ansible** | Everything running *inside* the VM, and its config | Any app/config change (often — it is idempotent) |

### Why Ansible instead of more cloud-init

Cloud-init is used **only** for what it is good at: creating the login user and
injecting the SSH key at clone time. Application configuration is Ansible's
job, for three reasons:

- Driving app setup through Proxmox's cloud-init integration proved unreliable
  here — long user-data payloads hung or timed out on first boot.
- Cloud-init effectively runs **once**. Changing a setting afterwards means
  rebuilding the VM; Ansible re-runs against a live host in seconds.
- Failures are visible. A failed Ansible task prints a task name and stops;
  a failed cloud-init step is buried in the guest's journal.

Terraform + Packer alone *could* stand up the VM, but every configuration
change after that would be a rebuild.

### Design rules

- **The image is immutable.** Nothing mutates the template after `packer
  build` — clones are disposable and rebuildable from scratch.
- **State is small and external.** Terraform state lives in Terraform Cloud;
  the VMs hold no irreplaceable data. Real data lives on the NAS.
- **Secrets never enter git.** Only `.example` files are tracked — see
  [Secrets](#secrets).
- **Everything reproducible is in this repo.** What cannot be (Proxmox API
  tokens, Tailscale route approvals, the AIO domain submit) is documented as an
  explicit manual step in the runbook rather than left implicit.

## Architecture

What the pipeline actually produces, and the supporting infrastructure it
depends on (none of which this repo provisions):

```text
                     Internet
                        │
                        │  outbound only: Cloudflare DNS-01 (ACME)
                        │  no inbound ports, no public ingress
                        ▼
┌───────────────────────────────────────────────────────────┐
│ LAN 192.168.1.0/24                                        │
│                                                           │
│  ┌─────────────────────────┐      ┌────────────────────┐  │
│  │ Proxmox VE (pve)        │      │ TrueNAS            │  │
│  │  ├─ ubuntu-24.04-       │      │  ZFS mirror        │  │
│  │  │  template  (Packer)  │      │  SMB: media        │  │
│  │  ├─ VM: nextcloud       │◀────▶│   ├─ Familia (ro)  │  │
│  │  │   ├─ Caddy (TLS)     │ SMB  │   └─ <user> dirs   │  │
│  │  │   └─ Nextcloud AIO   │      └────────────────────┘  │
│  │  └─ VM: k3s             │                              │
│  └─────────────────────────┘      ┌────────────────────┐  │
│              ▲                    │ PiHole             │  │
│              └────────────────────│  local DNS records │  │
│                                   └────────────────────┘  │
└───────────────────────────────────────────────────────────┘
                        ▲
                        │ Tailscale subnet route + split-DNS
                   Off-LAN devices
```

- **Proxmox VE** — the hypervisor; the only thing this repo deploys onto.
- **TrueNAS** — bulk storage, mounted by apps over SMB (never a VM disk). See
  [TrueNAS/README.md](TrueNAS/README.md).
- **PiHole** — LAN DNS. Private hostnames (`nextcloud.…`, `pve.…`) resolve
  here and nowhere else.
- **Tailscale** — off-LAN access via an advertised **subnet route** plus
  split-DNS to PiHole. Not a public ingress; nothing is exposed to the
  internet.
- **Cloudflare** — DNS for the public zone, used *only* to answer ACME DNS-01
  challenges so services get real Let's Encrypt certs without opening ports.

## Repository map

| Path | What it is | Doc |
|---|---|---|
| `packer/ubuntu-24.04/` | Base template build (`proxmox-iso` builder) | [packer/README.md](packer/README.md) |
| `terraform/modules/base-vm/` | Shared module: clone a template into a VM | [modules/base-vm/README.md](terraform/modules/base-vm/README.md) |
| `terraform/projects/` | One folder per VM = one TFC workspace + state | [terraform/README.md](terraform/README.md) |
| `ansible/` | Playbook + roles that configure the running VMs | [ansible/README.md](ansible/README.md) |
| `scripts/` | Standalone ops helpers (disk vetting); not pipeline | [scripts/README.md](scripts/README.md) |
| `TrueNAS/` | NAS install + post-install hardening notes | [TrueNAS/README.md](TrueNAS/README.md) |
| `NEXTCLOUD.md` | End-to-end runbook for the Nextcloud deployment | — |
| `Makefile` | Installs pinned tooling; `make help` lists targets | — |

## Deployments

| Deployment | Terraform project | Ansible roles | Status |
|---|---|---|---|
| **Nextcloud** — AIO behind Caddy, TrueNAS storage, Tailscale reach | `projects/nextcloud` | `tailscale`, `nextcloud_aio`, `reverse_proxy` | Live — [runbook](NEXTCLOUD.md) |
| **k3s** — single-node Kubernetes VM | `projects/k3s` | — (none yet) | VM only |

## Toolchain

`make all` installs everything pinned: binaries into `~/.local/bin`, a Python
virtualenv at `.venv`, and Node tools into `.node_modules`.

```bash
make help              # list every target
make install           # tools + git hooks
./install-packer.sh    # Packer is installed separately
```

Two gotchas that cause most "command not found" reports:

- **Ansible lives only in the venv** — `source .venv/bin/activate` first.
- **Node is via nvm** — run `export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"`
  before `npx`.

Pinned versions (see the `Makefile`): Terraform `1.15.7`, Telmate/proxmox
provider `3.0.2-rc07`, terraform-docs `0.21.0`, ansible-core `2.17.14`. These
pins are load-bearing — a provider mismatch breaks `terraform init` — so don't
bump them casually.

## Secrets

Every file holding a real secret is git-ignored; only its `.example` twin is
tracked. Copy the example, fill it in, and the real file stays local.

| Real file (ignored) | Holds |
|---|---|
| `packer/ubuntu-24.04/variables.pkrvars.hcl` | Proxmox API token, console password hash |
| `terraform/projects/*/terraform.tfvars` | Proxmox API token, SSH key path |
| `ansible/inventory/hosts.yml` | VM addresses |
| `ansible/vault.yml` | **ansible-vault encrypted**: NAS SMB credentials, per-user app passwords, Cloudflare DNS token, Tailscale auth key, plus private-but-not-secret values (public domain, ACME email) |

Rules: passwords go in `vault.yml`, never in `group_vars` or role defaults.
SSH **private** keys stay in `~/.ssh/` (the deploy key is
`~/.ssh/homelab-proxmox`) — public keys may appear in example files, private
keys never get committed.

## Conventions

- **Conventional Commits**, enforced by commitlint. Versioning and
  `CHANGELOG.md` are automated by semantic-release — never hand-edit either.
- **pre-commit** runs on every commit: `terraform_docs`, `terraform_fmt`,
  `packer_fmt`, `packer_validate`, `markdownlint`, `shellcheck`, commitlint.
  (`ansible-lint`, `yamllint`, and `gitleaks` are configured but commented
  out — run `ansible-lint` manually.)
- **Terraform docs are generated.** The block between `BEGIN_TF_DOCS` and
  `END_TF_DOCS` in each Terraform README is written by `terraform-docs` —
  edit the variable descriptions in `.tf` files, not the table.
- **Ansible role variables are prefixed with the role name**
  (`nextcloud_aio_*`, `tailscale_*`, `reverse_proxy_*`); ansible-lint's
  production profile enforces this and must stay green.
- **Markdown**: heading levels increment by one (MD001), fenced blocks declare
  a language (MD040). MD013/MD033/MD060 are disabled.

## Proxmox API users

Both Packer and Terraform authenticate with their own scoped Proxmox user and
API token. The `pveum` commands to create them live with the tool that uses
them:

- Packer — [packer/README.md](packer/README.md#create-the-packer-user-in-proxmox)
- Terraform — [terraform/README.md](terraform/README.md#create-the-terraform-user-in-proxmox)
