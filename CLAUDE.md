# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this repo is

Homelab infrastructure for **Proxmox VE**, delivered as a
**Packer → Terraform → Ansible** pipeline. Packer bakes a base Ubuntu 24.04
template (Docker, Tailscale, the Elastic Agent package, and Elasticsearch's OS
prerequisites), Terraform clones it into VMs, and Ansible configures the
running VM. App/VM config is done in **Ansible, not cloud-init**
(the owner hit timeouts/hangs using cloud-init directly with Proxmox).

Docs are organised by scope: [README.md](README.md) holds the deployment
strategy and architecture, each component folder documents itself
([packer](packer/README.md), [terraform](terraform/README.md),
[ansible](ansible/README.md), [scripts](scripts/README.md),
[TrueNAS](TrueNAS/README.md)), and one top-level runbook per deployment covers
it end to end ([NEXTCLOUD.md](NEXTCLOUD.md) including backup/DR,
[MONITORING.md](MONITORING.md)). [TODO.md](TODO.md) is the single status
tracker — check items off there rather than editing status into this file or
`README.md`. Keep new docs in that structure rather than adding top-level
files.

## Layout

```text
packer/ubuntu-24.04/        Base template build (proxmox-iso builder); VM ID 9000
packer/ubuntu-26.04/        Same build on 26.04 LTS, VM ID 9001 so both coexist
terraform/
  modules/base-vm/          Shared Telmate/proxmox VM module
  projects/k3s/             One project = one TFC workspace + state
  projects/nextcloud/       (workspace "Nextcloud", Local execution mode)
  projects/monitoring/      (workspace "Monitoring"); also generates the
                            ansible/inventory/monitoring.yml fragment
ansible/
  playbooks/                site.yml imports the numbered playbooks in order
  roles/{common,docker_data}/                            Host prep
  roles/{tailscale,nextcloud_aio,reverse_proxy}/          Nextcloud
  roles/{es_certs,elasticsearch,es_security_bootstrap,kibana_tls,kibana,
         fleet_bootstrap,fleet_server,exporters,elastic_agent}/  Elastic
  inventory/                directory inventory + hand-authored group_vars/
  files/truenas/            vendored config applied to the NAS by hand
  .certs/, .secrets-cache/  generated CA + Fleet tokens, gitignored
scripts/                    Standalone ops helpers (disk vetting); not pipeline
Makefile                    Installs pinned tools; `make help` lists targets
```

## Decisions that are deliberate (do not "fix" these)

- **Monitoring is the Elastic Stack on ONE VM.** Single-node Elasticsearch,
  Kibana and Fleet Server all on the monitoring host. The six-VM version lives
  in the separate `homelab-proxmox-elastic` repo; that topology is more than
  this 32 GB mini-PC has spare alongside Nextcloud. APM, tracing and the OTel
  demo were given up to fit — full-text log search, Fleet-managed agents and
  the path to OSQuery/Elastic Security were not. **If a change needs a second
  monitoring VM, it belongs in the other repo** — do not propose growing this
  one back into a cluster.
- **Most of the Elastic roles are ported from that repo, comments included.**
  Those comments record bugs found only by running it live (Fleet's default
  output pointing at `localhost:9200`, `ELASTIC_PASSWORD_FILE` crash-looping
  at mode 644, Kibana needing whitespace-free JSON for `elasticsearch.hosts`,
  `force_basic_auth` being required against Kibana's API). Do not "tidy" them
  away — re-deriving any of them costs a live debugging session.
- **Elasticsearch's OS prerequisites are baked into the Packer template**, not
  applied by Ansible: `vm.max_map_count` (a hard bootstrap check — ES refuses
  to start below 262144), memlock/nofile limits, and `/opt/elastic`. Changing
  any of them means rebuilding the template. `common`'s asserts only *verify*
  them and say so in the failure message.
- **The monitoring host is in three inventory groups at once** (`monitoring`,
  `elasticsearch`, `kibana`), written that way by Terraform. That is what lets
  the ported roles keep their `groups['elasticsearch'][0]` lookups intact;
  collapsing the groups would mean rewriting every one of them.
- **Single node means replicas must be zero.** `es_security_bootstrap` PUTs
  `number_of_replicas: 0` onto the `logs@custom`/`metrics@custom`/
  `synthetics@custom`/`traces@custom` component templates — the supported
  override point Fleet's own index templates reference, so it survives stack
  upgrades. Without it cluster health never leaves yellow.
- **The Prometheus exporters are deliberate, not leftovers.** Elastic ships no
  integration for TrueNAS or for Nextcloud's application metrics, so both
  arrive through the Elastic Agent's Prometheus integration in collector mode.
  The package-policy input key is `prometheus-prometheus/metrics`, verified
  against the published package manifest at
  `epr.elastic.co/package/prometheus/<version>/` — never guess these, the
  equivalent guess for APM in the other repo cost real debugging time.
- **`ansible/inventory/` is a directory inventory, not a single file.** Every
  fragment inside is merged, which is what lets each Terraform project generate
  its own (`terraform/projects/monitoring` writes `inventory/monitoring.yml`)
  without clobbering another project's hosts. `hosts.yml` stays hand-authored.
  `ansible.cfg` adds `.example` to `inventory_ignore_extensions` so
  `hosts.yml.example` is not parsed as a real source.
- **The 26.04 template drops `storage.layout`, and that is what turns LVM on.**
  Subiquity ignores `storage.config` entirely when `storage.layout` is also
  present. `packer/ubuntu-24.04` sets both, so its LVM block is dead and the
  24.04 template has **no LVM** — which is also why its volumes summing to 35G
  on a 32G disk never failed to build. Do not "restore" `layout:` for symmetry.
- **The Docker data disk is Terraform's and Ansible's, never Packer's.** The OS
  disk (24G, LVM) is baked; the data disk is attached by `base-vm`'s
  `data_disk_size` and turned into `docker-vg`/`docker-lv` by the
  `docker_data` role at first run. Partitioning it in the golden image would
  give every clone byte-identical PV/VG UUIDs, so moving one host's disk to
  another would need `vgimportclone` — which defeats the reason the disks are
  split. A VM meant to *receive* an existing disk is created with
  `data_disk_size = null`.
- **Container data lives on the data disk, not `/opt`.** Elasticsearch's
  `esdata` and Nextcloud AIO's mastercontainer are named Docker volumes under
  `/var/lib/docker/volumes`. `elastic_base_dir` holds only compose files, certs
  and secrets. So `data_disk_size`, not `disk0_size`, is the ILM retention
  ceiling — that is why monitoring's 100G moved from disk0 to the data disk.
- **Images live on the data disk too, via a bind mount of `/var/lib/containerd`.**
  Docker's containerd image store keeps images and layers in containerd's
  root, which a mount at `/var/lib/docker` does not cover — that filled the
  monitoring VM's 12G root. `docker_data` bind-mounts
  `/var/lib/docker/containerd-root` over `/var/lib/containerd`. Do not swap it
  for `root =` in `/etc/containerd/config.toml` (a package conffile) or for
  disabling the image store in `daemon.json` (it is Docker's default). Systemd
  drop-ins make containerd and Docker *require* both mounts, so a host missing
  its data disk boots with Docker down instead of running it empty on the OS root.
- **No logical volume is sized `-1`.** The leftover extents in `ubuntu-vg` are
  deliberate headroom: `lvextend` + `resize2fs` grows whatever fills first
  without repartitioning. Filling the group would take that away.
- **Terraform generates inventory; it never writes `group_vars/`.** Same split
  as the Elastic repo: addresses are machine state, tuning is hand-authored.
- **Inventory host names differ from Proxmox VM names** (`monitoring-vm` vs
  `monitoring`, `nextcloud-vm` vs `nextcloud`). Ansible warns and resolves
  ambiguously when a host and a group share a name, and the groups are
  `monitoring` and `nextcloud`.
- **The Elastic Agent package is pre-installed by Packer and left disabled.**
  There is nothing to enroll against at build time, so a started agent would
  just fill the journal retrying. The `elastic_agent` role enrolls and starts
  it. That role's version check doubles as the install path, so a VM cloned
  from an older template still works.
- **Grafana Alloy is gone.** It belonged to a short-lived Prometheus/Grafana/
  Loki design that preceded this one. The `elastic_agent` role stops and
  disables any leftover `alloy` service on VMs cloned from the old template —
  stopped, not purged, because removing a package the template installed is
  the template's job.
- **TrueNAS pushes Graphite, it is not scraped.** TrueNAS is not
  Ansible-managed and cannot take an agent; its built-in Reporting Exporter
  speaks Graphite, and `graphite_exporter` translates. The mapping file is
  vendored at a pinned upstream tag (v2.2.1) under `roles/exporters/files/`.
- **`/etc/netdata/netdata.conf` on the NAS is a documented manual step**, and a
  TrueNAS update overwrites it. That is the first thing to check when NAS
  metrics go blank after an upgrade.
- **Kibana serves a Let's Encrypt cert for `kibana_fqdn` on 443**, from the
  `kibana_tls` role (certbot + Cloudflare DNS-01, ported from the six-VM repo).
  `kibana_fqdn` is *derived* — `kibana.` + the zone of `nextcloud_domain` — so
  the real domain never appears in the tracked repo; do not write it out
  literally. The A record is PiHole's, not this repo's. Every Ansible call to
  Kibana goes to `127.0.0.1:{{ kibana_port }}` with `validate_certs: false`, so
  which cert is served never matters to automation. Kibana's cert is only for
  browsers: agents talk to Fleet Server and Elasticsearch, which keep the
  internal CA. `acme_email` and `cloudflare_dns_api_token` live in
  `group_vars/all.yml` because Caddy on the Nextcloud VM uses them too.
- **One Cloudflare token serves both certs (Caddy and Kibana's certbot).**
  Rotating it or fixing a failed renewal: `sops secrets.yaml`, `direnv reload`,
  then re-run `10-nextcloud.yml --limit nextcloud-vm` and
  `35-kibana.yml --limit monitoring-vm`. Full steps and verification are in
  [NEXTCLOUD.md](NEXTCLOUD.md#rotating-the-cloudflare-api-token-or-a-cert-failed-to-renew).
  Never paste the token into a role default, `.ini` or `.env` by hand — those
  files are rendered from it.

## Toolchain & how to run things

`make all` installs pinned tools into `~/.local/bin`, a Python venv at `.venv`,
and Node tools at `.node_modules`. Key gotchas when running linters/commands:

- **Ansible lives only in the venv.** The root `.envrc` adds `.venv/bin` to
  `PATH`, so with direnv loaded it just works; otherwise
  `source .venv/bin/activate` first or `ansible-playbook`/`ansible-lint` will be
  "command not found".
- **direnv and age come from apt, not the Makefile** — one hooks the shell, the
  other holds a key outside the repo. `sops` is pinned by `make install-sops`.
- **Node is via nvm** — `npx` is not on `PATH` by default. Run
  `export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"` before `npx`.
- Pinned versions (see Makefile): Terraform `1.15.7`, Telmate/proxmox provider
  `3.0.2-rc07`, terraform-docs `0.21.0`, ansible-core `2.17.14`. Don't bump these
  casually — exact pins are load-bearing (e.g. provider rc mismatch breaks init).

Common checks:

```bash
# Ansible (from ansible/, venv active)
ansible-lint                           # MUST pass at the production profile
ansible-playbook playbooks/site.yml --syntax-check
ansible-inventory --graph              # confirm the directory inventory merged

# Terraform (per project dir)
terraform fmt -recursive && terraform validate
terraform-docs markdown table --output-file README.md .

# Docs / shell
npx markdownlint-cli2 <file>.md        # MD013/MD033/MD060 are disabled
shellcheck <script>.sh

# Packer (from packer/ubuntu-24.04/)
packer validate .                       # PKR_VAR_* come from direnv
```

`pre-commit` runs terraform_docs/fmt, packer_fmt/validate, markdownlint,
shellcheck, and **commitlint** on every commit (ansible-lint/yamllint/gitleaks
are present but commented out — run ansible-lint manually).

## Conventions

- **Conventional Commits**, enforced by commitlint + semantic-release (versioning
  and CHANGELOG.md are automated — don't hand-edit CHANGELOG.md or bump versions).
- **Ansible role variables are prefixed with the role name** (`nextcloud_aio_*`,
  `tailscale_*`, `reverse_proxy_*`, `exporters_*`, `elastic_agent_*`).
  ansible-lint's
  production profile enforces this — including on `register:` names, where a
  leading underscore is allowed but the role prefix still has to follow it
  (`_fleet_bootstrap_kibana`, not `_fb_kibana`). The `es_*` names the ported
  Elastic roles use are the exception: they live in `inventory/group_vars/`
  rather than a role's `defaults/`, which is both what makes them visible
  cross-role and what keeps the linter satisfied. Non-secret shared
  values live in `inventory/group_vars/`, not role defaults; anything a role on
  host A needs to know about host B **must** live there, because role defaults
  are not visible cross-host. Keep ansible-lint green.
- **Terraform multi-project**: each dir under `terraform/projects/` is its own TFC
  workspace and state file, all consuming `modules/base-vm`. Org is
  `colac_homelab`; workspaces use **Local** execution mode (they apply against
  Proxmox from the operator's machine, so remote runs can't read `../../modules`).
- Markdown: keep heading levels incrementing by one (MD001); add a language to
  fenced code blocks (MD040).

## Secrets — SOPS + age + direnv

Every credential lives in **one** file, `secrets.yaml` at the repo root,
SOPS-encrypted with age. Same scheme as `homelab-proxmox-elastic`, same age key.

- **`secrets.yaml` IS committed.** SOPS encrypts values in place, so the file is
  ciphertext. It is deliberately absent from `.gitignore` and allowlisted in
  `.gitleaks.toml`. Adding it to `.gitignore` would silently stop it from ever
  being committed — that was a real bug in the other repo. Only the age private
  key (`~/.config/sops/age/keys.txt`) and decrypted copies (`*.decrypted`,
  `*.dec.yaml`) stay out.
- **Never read, print, `cat`, `grep` or `sed` `secrets.yaml`, any `.envrc`, the
  age key, or the git-ignored `*.tfvars` / `*.pkrvars.hcl`.** Reference secrets
  by variable name only. A Bash deny rule enforces this; it restricts the agent,
  not direnv, and both hold.
- **direnv runs in the human's shell, before the agent starts.** The root
  `.envrc` decrypts once and exports every key; `packer/`, `terraform/` and
  `ansible/` inherit via `source_up` and remap to `PKR_VAR_*`, `TF_VAR_*` and
  plain uppercase names respectively. Ansible reads those back with
  `lookup('env', …)` in `inventory/group_vars/` — that is the *only* place they
  are consumed. Never reintroduce a literal secret into `group_vars` or a role
  default.
- **No var-files are required.** `packer build`, `terraform apply` and
  `ansible-playbook` all run bare. `*.tfvars` / `*.pkrvars.hcl` remain
  git-ignored and, if present, still override the env vars — that is intentional
  so an existing local file keeps working.
- **Editing `secrets.yaml` needs no direnv action** — it reloads on the next
  `cd`, or `direnv reload`. **Editing any `.envrc`** makes direnv treat it as
  untrusted (`direnv: error .envrc is blocked`) until re-approved — tell the
  human to run `make direnv-allow` (re-approves all four at once).
- The root `.envrc` decrypts with a `while read` loop, **not**
  `eval "$(… | sed 's/^/export /')"` like the elastic repo. eval re-parses the
  plaintext as shell, so any value with a space, quote or `$` breaks or gets
  word-split — verified, it drops the value entirely. Do not "simplify" it back.
- `nextcloud_users_json` is a single-line JSON array because
  `sops -d --output-type dotenv` emits flat `key=value` pairs only.
  `group_vars/nextcloud.yml` restores the structure with `| from_json`.
- **Generated Elastic material does NOT go in `secrets.yaml`.** The internal CA
  and node cert live in `ansible/.certs/`, the Fleet service token and
  enrollment API keys in `ansible/.secrets-cache/` — both gitignored. They are
  machine state, not human choices; losing them is recoverable (the roles
  regenerate against an empty cluster), committing them is not. Same split the
  six-VM repo settled on.
- SSH **private** keys stay in `~/.ssh/` (the deploy key is `~/.ssh/homelab-proxmox`).
  Public keys may be embedded in example files; private keys never get committed.
- `secrets.yaml.example` is the tracked plaintext key reference. Keep its
  **keys** in sync with `secrets.yaml`; never put a real value in it.

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
the VM disk. Each person in `nextcloud_aio_users` (from `nextcloud_users_json`
in `secrets.yaml`) with `nas_folder:
true` gets `media/<username>` mounted privately (`applicable_users`) — that's
the phone auto-upload target. `Familia` is one **read-only** mount for
everyone, `admin` included: curating it happens over SMB against TrueNAS,
where it's an instant same-dataset rename instead of the copy-and-delete
Nextcloud would do across mounts. Mounts are **create-only** — the role never
updates or removes an existing mount, so changing a mount's host, scoping, or
read-only flag means `occ files_external:delete <id> -y` first, then re-run.
