# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this repo is

Homelab infrastructure for **Proxmox VE**, delivered as a
**Packer → Terraform → Ansible** pipeline. Packer bakes a base Ubuntu 24.04
template (Docker + Tailscale), Terraform clones it into VMs, and Ansible
configures the running VM. App/VM config is done in **Ansible, not cloud-init**
(the owner hit timeouts/hangs using cloud-init directly with Proxmox).

Docs are organised by scope: [README.md](README.md) holds the deployment
strategy and architecture, each component folder documents itself
([packer](packer/README.md), [terraform](terraform/README.md),
[ansible](ansible/README.md), [scripts](scripts/README.md),
[TrueNAS](TrueNAS/README.md)), and [NEXTCLOUD.md](NEXTCLOUD.md) is the
end-to-end runbook for the flagship deployment (including backup/DR). Keep new
docs in that structure rather than adding top-level files.

## Layout

```text
packer/ubuntu-24.04/        Base template build (proxmox-iso builder)
terraform/
  modules/base-vm/          Shared Telmate/proxmox VM module
  projects/k3s/             One project = one TFC workspace + state
  projects/nextcloud/       (workspace "Nextcloud", Local execution mode)
ansible/
  site.yml                  Single playbook; roles run in order
  roles/{tailscale,nextcloud_aio,reverse_proxy}/
  group_vars/, inventory/
scripts/                    Standalone ops helpers (disk vetting); not pipeline
Makefile                    Installs pinned tools; `make help` lists targets
```

## Toolchain & how to run things

`make all` installs pinned tools into `~/.local/bin`, a Python venv at `.venv`,
and Node tools at `.node_modules`. Key gotchas when running linters/commands:

- **Ansible lives only in the venv** — `source .venv/bin/activate` first, or
  `ansible-playbook`/`ansible-lint` will be "command not found".
- **Node is via nvm** — `npx` is not on `PATH` by default. Run
  `export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"` before `npx`.
- Pinned versions (see Makefile): Terraform `1.15.7`, Telmate/proxmox provider
  `3.0.2-rc07`, terraform-docs `0.21.0`, ansible-core `2.17.14`. Don't bump these
  casually — exact pins are load-bearing (e.g. provider rc mismatch breaks init).

Common checks:

```bash
# Ansible (from ansible/, venv active)
ansible-lint site.yml roles/...        # MUST pass at the production profile
ansible-playbook site.yml --syntax-check

# Terraform (per project dir)
terraform fmt -recursive && terraform validate
terraform-docs markdown table --output-file README.md .

# Docs / shell
npx markdownlint-cli2 <file>.md        # MD013/MD033/MD060 are disabled
shellcheck <script>.sh

# Packer (from packer/ubuntu-24.04/)
packer validate -var-file=variables.pkrvars.hcl .
```

`pre-commit` runs terraform_docs/fmt, packer_fmt/validate, markdownlint,
shellcheck, and **commitlint** on every commit (ansible-lint/yamllint/gitleaks
are present but commented out — run ansible-lint manually).

## Conventions

- **Conventional Commits**, enforced by commitlint + semantic-release (versioning
  and CHANGELOG.md are automated — don't hand-edit CHANGELOG.md or bump versions).
- **Ansible role variables are prefixed with the role name** (`nextcloud_aio_*`,
  `tailscale_*`, `reverse_proxy_*`). ansible-lint's production profile enforces
  this; non-secret shared values live in `group_vars`, not role defaults. Keep
  ansible-lint green.
- **Terraform multi-project**: each dir under `terraform/projects/` is its own TFC
  workspace and state file, all consuming `modules/base-vm`. Org is
  `colac_homelab`; workspaces use **Local** execution mode (they apply against
  Proxmox from the operator's machine, so remote runs can't read `../../modules`).
- Markdown: keep heading levels incrementing by one (MD001); add a language to
  fenced code blocks (MD040).

## Secrets — never commit these

Real secret files are git-ignored; only `.example` versions are tracked.

- `ansible/vault.yml` — encrypted with **ansible-vault**. Holds the TrueNAS SMB
  user + password, the `nextcloud_aio_users` list (Nextcloud usernames **and**
  passwords — names live here too, so none are hard-coded in the repo), the
  Cloudflare DNS-API token, and the Tailscale auth key.
  Passwords go here, never plaintext in `group_vars` or roles. It also carries a
  few non-secret-but-private values (the public domain, ACME email) so the
  hostname stays out of the tracked repo.
- `*.tfvars` and `*.pkrvars.hcl` — Proxmox API tokens, password hashes.
- SSH **private** keys stay in `~/.ssh/` (the deploy key is `~/.ssh/homelab-proxmox`).
  Public keys may be embedded in example files; private keys never get committed.

## Nextcloud specifics (current design)

AIO in reverse-proxy mode (`APACHE_PORT=11000`, localhost-bound), served privately
at `https://nextcloud.example.com`. TLS is terminated by a **Caddy** reverse
proxy on the VM using a Let's Encrypt cert via **Cloudflare DNS-01** (no public
exposure; Cloudflare only answers DNS). Tailscale provides off-LAN reach via a
`--advertise-routes` subnet route + PiHole split-DNS — `tailscale serve` is **not**
used (it can't present a custom-domain cert). Cloudflare Tunnel was rejected
(public-by-default, MITMs traffic, upload cap). The AIO domain submit and the
Tailscale route/split-DNS approvals are unavoidable one-time manual steps.

Storage model: everything lives on TrueNAS as SMB external storage, never on
the VM disk. Each person in `nextcloud_aio_users` (vault) with `nas_folder:
true` gets `media/<username>` mounted privately (`applicable_users`) — that's
the phone auto-upload target. `Familia` is one **read-only** mount for
everyone, `admin` included: curating it happens over SMB against TrueNAS,
where it's an instant same-dataset rename instead of the copy-and-delete
Nextcloud would do across mounts. Mounts are **create-only** — the role never
updates or removes an existing mount, so changing a mount's host, scoping, or
read-only flag means `occ files_external:delete <id> -y` first, then re-run.
