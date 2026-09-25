# Homelab Proxmox

Infrastructure-as-code for a single-node **Proxmox VE** homelab. One hardened
base image, one reusable VM module, one configuration playbook — built as a
**Packer → Terraform → Ansible** pipeline.

Heavily "inspired" by
<https://github.com/bcochofel/homelab-proxmox-core/tree/main>.

- **New here?** Read the strategy and architecture below.
- **Want to deploy something?** [NEXTCLOUD.md](NEXTCLOUD.md) and
  [MONITORING.md](MONITORING.md) are the complete from-zero runbooks for the
  two deployments.
- **Working on one component?** Each folder has its own README — see
  [Repository map](#repository-map).
- **What is done and what is not?** [TODO.md](TODO.md) is the single status
  tracker.

This is a monorepo: one `make install`, one Packer template, one Ansible
playbook tree, and one Terraform project per VM. `ansible-playbook
playbooks/site.yml` redeploys everything below from scratch.

## Deployment strategy

Three stages, each owning exactly one thing. The split is deliberate: a stage
can be re-run without redoing the others, and each produces an artifact the
next one consumes.

```text
┌──────────┐  bakes    ┌─────────────────────┐
│  Packer  │──────────▶│ ubuntu-24.04-       │  Proxmox VM template:
│          │           │ template            │  hardened Ubuntu 24.04 LTS,
└──────────┘           └─────────────────────┘  Docker, Tailscale, Elastic
                                                Agent (disabled), sealed
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
| **Packer** | The golden image: OS, hardening, Docker, Tailscale, the Elastic Agent package, and the Elasticsearch OS prerequisites | The base OS or baked-in tooling changes (rare) |
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
┌──────────────────────────────────────────────────────────────┐
│ LAN 192.168.1.0/24                                           │
│                                                              │
│  ┌──────────────────────────────┐     ┌───────────────────┐  │
│  │ Proxmox VE (pve)             │     │ TrueNAS           │  │
│  │  ├─ ubuntu-24.04-template    │     │  ZFS mirror       │  │
│  │  │     (Packer)              │ SMB │  SMB: media       │  │
│  │  ├─ VM: nextcloud  ◀─────────┼────▶│   ├─ Familia (ro) │  │
│  │  │    ├─ Caddy (TLS)         │     │   └─ <user> dirs  │  │
│  │  │    ├─ Nextcloud AIO       │     │                   │  │
│  │  │    └─ elastic-agent ──┐   │     │  netdata ───┐     │  │
│  │  │                       │   │     └─────────────┼─────┘  │
│  │  ├─ VM: monitoring       │   │      metrics+logs │        │
│  │  │    ├─ Elasticsearch ◀─┘   │         graphite  │        │
│  │  │    ├─ Fleet Server        │                   │        │
│  │  │    ├─ Kibana              │                   │        │
│  │  │    └─ exporters ◀─────────┼───────────────────┘        │
│  │  └─ VM: k3s                  │                            │
│  └──────────────────────────────┘     ┌───────────────────┐  │
│              ▲                        │ PiHole            │  │
│              └────────────────────────│  local DNS records│  │
│                                       └───────────────────┘  │
└──────────────────────────────────────────────────────────────┘
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
| `packer/ubuntu-24.04/` | Base template build (`proxmox-iso` builder) — what everything deployed was cloned from | [packer/README.md](packer/README.md) |
| `packer/ubuntu-26.04/` | The same build on 26.04 LTS; nothing clones from it until a project's `template_name` changes | [packer/README.md](packer/README.md) |
| `terraform/modules/base-vm/` | Shared module: clone a template into a VM | [modules/base-vm/README.md](terraform/modules/base-vm/README.md) |
| `terraform/projects/` | One folder per VM = one TFC workspace + state | [terraform/README.md](terraform/README.md) |
| `ansible/` | Playbooks + roles that configure the running VMs | [ansible/README.md](ansible/README.md) |
| `scripts/` | Standalone ops helpers (disk vetting); not pipeline | [scripts/README.md](scripts/README.md) |
| `TrueNAS/` | NAS install + post-install hardening notes | [TrueNAS/README.md](TrueNAS/README.md) |
| `NEXTCLOUD.md` | End-to-end runbook for the Nextcloud deployment | — |
| `MONITORING.md` | End-to-end runbook for the monitoring deployment | — |
| `TODO.md` | Status tracker for every deployment and open item | — |
| `Makefile` | Installs pinned tooling; `make help` lists targets | — |
| `secrets.yaml` | Every credential, SOPS-encrypted — committed as ciphertext | [see below](#secrets) |
| `secrets.yaml.example` | Plaintext reference for the keys inside it | — |
| `.envrc` (+ one per tool dir) | direnv: decrypt once, export per directory | [see below](#secrets) |

## Deployments

| Deployment | Terraform project | Ansible roles | Status |
|---|---|---|---|
| **Nextcloud** — AIO behind Caddy, TrueNAS storage, Tailscale reach | `projects/nextcloud` | `tailscale`, `nextcloud_aio`, `reverse_proxy` | Live — [runbook](NEXTCLOUD.md) |
| **Monitoring** — the Elastic Stack (single-node Elasticsearch, Kibana, Fleet) on one VM, watching Nextcloud and TrueNAS | `projects/monitoring` | `es_certs`, `elasticsearch`, `es_security_bootstrap`, `kibana_tls`, `kibana`, `fleet_bootstrap`, `fleet_server`, `exporters`, `elastic_agent` | Built, not yet run live — [runbook](MONITORING.md) |
| **k3s** — single-node Kubernetes VM | `projects/k3s` | — (none yet) | VM only |

### Why the Elastic Stack, on one VM

A six-VM version of this exists in a separate repo
(`homelab-proxmox-elastic`) — Elasticsearch × 3, Kibana with Fleet, an APM
server, an OpenTelemetry demo. It works, and it is the better teaching
artefact. It also costs six VMs and roughly 12 GB, which is more than this
32 GB mini-PC has spare alongside Nextcloud.

The deployment here is the **same stack with the topology collapsed onto one
VM**: single-node Elasticsearch, Kibana and Fleet Server together, 8 GB. Most
of the role code is ported directly from that repo. APM, tracing and the OTel
demo were given up to fit; full-text log search, Fleet-managed agents and the
path to OSQuery and Elastic Security were not.

Keep it that way — if a change needs a second VM, it belongs in the other
repo. The full comparison is in [MONITORING.md](MONITORING.md).

## Toolchain

`make all` installs everything pinned: binaries into `~/.local/bin`, a Python
virtualenv at `.venv`, and Node tools into `.node_modules`.

```bash
make help              # list every target
make install           # tools + git hooks
./install-packer.sh    # Packer is installed separately
```

`direnv` and `age` are the two exceptions: install them from the OS package
manager (`apt-get install direnv age`, then hook direnv into your shell), since
one hooks the shell and the other holds a key outside the repo. `make install`
checks for both and refuses to run `direnv allow` without them.

Gotchas that cause most "command not found" reports:

- **Ansible lives only in the venv.** The root `.envrc` puts `.venv/bin` on
  `PATH`, so with direnv active `ansible-playbook` just works; without it,
  `source .venv/bin/activate` first.
- **Node is via nvm** — run `export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"`
  before `npx`.

Pinned versions (see the `Makefile`): Terraform `1.15.7`, Telmate/proxmox
provider `3.0.2-rc07`, terraform-docs `0.21.0`, ansible-core `2.17.14`. These
pins are load-bearing — a provider mismatch breaks `terraform init` — so don't
bump them casually.

## Secrets

**One encrypted file, decrypted once, delivered per directory.** Every
credential the three tools need lives in `secrets.yaml` at the repo root,
encrypted with [SOPS](https://github.com/getsops/sops) using an
[age](https://github.com/FiloSottile/age) key. SOPS encrypts *values in place*,
so the file on disk — and in git — is ciphertext. Unlike most `secrets.*`
conventions, **it is meant to be committed**; `.gitleaks.toml` allowlists it for
exactly that reason, and `.gitignore` deliberately does *not* list it.

[direnv](https://direnv.net) turns that file into environment variables when you
`cd`. The root `.envrc` decrypts once; each tool directory inherits via
`source_up` and remaps only what that tool needs:

| You `cd` into | direnv exports | Read by |
|---|---|---|
| repo root | `SOPS_AGE_KEY_FILE`, every key in `secrets.yaml`, `PROXMOX_ENDPOINT`, `PROXMOX_NODE`, `PROXMOX_TLS_INSECURE`; adds `.venv/bin` to `PATH` | — |
| `packer/` | `PKR_VAR_*` (API URL, Packer token, node, TLS flag, console password hash, and the deploy key's public half read from `~/.ssh`) | `packer build` |
| `terraform/` (and every project under it) | `TF_TOKEN_app_terraform_io`, `TF_VAR_pm_api_*`, `TF_VAR_pm_tls_insecure` | `terraform apply` |
| `ansible/` | `ANSIBLE_CONFIG` plus the app secrets, read back with `lookup('env', …)` in `inventory/group_vars/` | `ansible-playbook` |

The consequence is that **no `*.tfvars` or `*.pkrvars.hcl` file is needed at
all**, and there is no vault password to type: `terraform apply`,
`packer build` and `ansible-playbook` each work bare, from their own directory.
The `.example` files that remain are optional non-secret overrides.

```bash
age-keygen -o ~/.config/sops/age/keys.txt   # first time only
chmod 600 ~/.config/sops/age/keys.txt       # then add the age1… public key
                                            # to .sops.yaml as a recipient
sops secrets.yaml       # decrypt -> $EDITOR -> re-encrypt on save
sops -d secrets.yaml    # print decrypted (read-only)
make direnv-allow       # after editing ANY .envrc — direnv blocks a changed
                        # one until re-approved. Editing secrets.yaml needs
                        # nothing: it reloads on the next cd, or `direnv reload`
```

See [`secrets.yaml.example`](secrets.yaml.example) for every key and what it is
for — it is the tracked, readable reference, since a reader without the age key
cannot see inside the encrypted file.

**What still stays out of git entirely:**

| Path | Why |
|---|---|
| `~/.config/sops/age/keys.txt` | The age **private** key. Everything else is recoverable; this is not. |
| `~/.ssh/homelab-proxmox` | Deploy key, private half. Public halves may appear in tracked files; private keys never get committed. |
| `ansible/inventory/hosts.yml` | VM addresses (hand-authored) |
| `ansible/inventory/monitoring.yml` | VM address, **generated by Terraform** |
| `ansible/.certs/` | Internal Elastic CA, node certificate and key — **generated**, not human-chosen |
| `ansible/.secrets-cache/` | Fleet service token and enrollment API keys — **minted** by the API |

The last two are the deliberate exception to "secrets go in `secrets.yaml`":
they are machine state, not human choices. Losing them is recoverable — the
roles regenerate them against an empty cluster — so round-tripping them through
an encrypted file would add risk without adding control.

`ansible/inventory/` is a **directory** inventory: every file in it is merged.
That is what lets each Terraform project generate its own fragment without
clobbering another project's hosts, while `inventory/group_vars/` stays
hand-authored and tracked. Terraform never writes `group_vars/`.

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
