# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this repo is

The **monitoring layer** of a three-repo homelab on Proxmox VE: the Elastic
Stack on ONE VM (single-node Elasticsearch, Kibana, Fleet Server), Prometheus
exporters for TrueNAS and Nextcloud, and Fleet enrollment of an Elastic Agent
on **every** host — including hosts other repos own.

| Repo (siblings under `~/git-repos/`) | Owns |
|---|---|
| `homelab-proxmox` — core | Packer templates, `base-vm` module, `colac.homelab` collection, homelab-wide docs (`docs/ARCHITECTURE.md`) |
| `homelab-proxmox-monitoring` — **this** | The monitoring VM and observability for every host |
| `homelab-proxmox-workloads` | Apps: Nextcloud, k3s |

Work that changes the template, the module or `common`/`docker_data` belongs
in core — propose it there, then bump the pin here. Work on Nextcloud itself
belongs in workloads. [README.md](README.md) has the architecture and the
contracts between repos; [RUNBOOK.md](RUNBOOK.md) is the from-zero runbook;
[TODO.md](TODO.md) is the single status tracker for this repo — check items
off there, not here.

## Layout

```text
terraform/                  The monitoring VM (TFC workspace "Monitoring", Local
                            execution); base-vm from core at ?ref=v2.0.0; also
                            writes ansible/inventory/monitoring.yml
ansible/
  playbooks/                site.yml imports the numbered playbooks in order
  roles/elastic_preflight/  This repo's asserts (max_map_count, stack secrets)
  roles/{es_certs,elasticsearch,es_security_bootstrap,kibana_tls,kibana,
         fleet_bootstrap,fleet_server,exporters,elastic_agent}/
  inventory/                directory inventory: monitoring.yml (Terraform),
                            hosts.yml (agent targets, hand-authored), group_vars/
  requirements.yml          colac.homelab pinned to a core tag + Galaxy collections
  collections/              installed by `mise run setup` (git-ignored)
  files/truenas/            vendored config applied to the NAS by hand
  .certs/, .secrets-cache/  generated CA + Fleet tokens, git-ignored
.mise/sops-exec             the only thing that decrypts secrets.yaml
mise.toml                   tools, env, tasks (`mise tasks`)
```

## Decisions that are deliberate (do not "fix" these)

- **ONE VM.** The six-VM version lives in `homelab-proxmox-elastic`; that
  topology is more than this 32 GB mini-PC has spare alongside Nextcloud. APM,
  tracing and the OTel demo were given up to fit. **If a change needs a second
  monitoring VM, it belongs in the other repo** — do not propose growing this
  one back into a cluster.
- **Most Elastic roles are ported from that repo, comments included.** Those
  comments record bugs found only by running it live (Fleet's default output
  pointing at `localhost:9200`, `ELASTIC_PASSWORD_FILE` crash-looping at mode
  644, Kibana needing whitespace-free JSON for `elasticsearch.hosts`,
  `force_basic_auth` being required against Kibana's API). Do not "tidy" them
  away — re-deriving any of them costs a live debugging session.
- **The ES OS prerequisites are the core template's, not Ansible's.**
  `vm.max_map_count`, memlock/nofile limits and `/opt/elastic` are baked by
  core's Packer. `elastic_preflight` only *verifies* them and its failure
  message names the core rebuild. Never add a sysctl task here.
- **This repo owns observability for every host, but configures only its
  own.** `00-bootstrap.yml` targets `monitoring` only. Hosts in the `agents`
  group (`inventory/hosts.yml`) see just `20-elastic-certs` (the CA) and
  `50-elastic-agent` (enrollment). Never add a play that touches an agent
  target's disks, Docker or apps — that is its owning repo's job.
- **The monitoring host is in three inventory groups** (`monitoring`,
  `elasticsearch`, `kibana`), written that way by Terraform. That is what lets
  the ported roles keep `groups['elasticsearch'][0]` intact.
- **Single node means replicas must be zero.** `es_security_bootstrap` PUTs
  `number_of_replicas: 0` onto the `logs@custom`/`metrics@custom`/
  `synthetics@custom`/`traces@custom` component templates — the supported
  override point Fleet's index templates reference, so it survives upgrades.
- **The Prometheus exporters are deliberate.** Elastic ships no integration for
  TrueNAS or Nextcloud's app metrics. The package-policy input key is
  `prometheus-prometheus/metrics`, verified against
  `epr.elastic.co/package/prometheus/<version>/` — never guess these.
- **`ansible/inventory/` is a directory inventory.** Terraform writes
  `monitoring.yml`, a human writes `hosts.yml`, neither clobbers the other.
  Terraform never writes `group_vars/`: addresses are machine state, tuning is
  hand-authored.
- **Inventory host names differ from VM names** (`monitoring-vm` vs
  `monitoring`) because a host and a group must not share a name.
- **Container data lives on the data disk.** `esdata` is a named Docker volume
  under `/var/lib/docker/volumes`, and `colac.homelab.docker_data` also
  bind-mounts containerd's image store there. So `data_disk_size` (100G), not
  `disk0_size`, is the ILM retention ceiling.
- **The Elastic Agent package is pre-installed by core's Packer and left
  disabled**; `elastic_agent` enrolls and starts it, and its version check
  doubles as the install path for VMs cloned from older templates. It also
  stops (not purges) any leftover Grafana Alloy service.
- **TrueNAS pushes Graphite; it is not scraped.** The mapping file is vendored
  at upstream tag v2.2.1 under `roles/exporters/files/`.
  `/etc/netdata/netdata.conf` on the NAS is a documented manual step that a
  TrueNAS update overwrites — first thing to check when NAS metrics go blank.
- **Kibana serves a Let's Encrypt cert for `kibana_fqdn` on 443** (certbot +
  Cloudflare DNS-01). `kibana_fqdn` is *derived* — `kibana.` + the zone of
  `nextcloud_domain` — so the real domain never appears in the repo; do not
  write it out. The A record is PiHole's. Every Ansible call to Kibana goes to
  `127.0.0.1:{{ kibana_port }}` with `validate_certs: false`.
- **This repo's Cloudflare token is its own.** Nextcloud's Caddy (workloads
  repo) has a separate token, so rotating one cannot break the other. Steps:
  [RUNBOOK.md](RUNBOOK.md#rotating-the-cloudflare-api-token).
- **`stack_version` in `group_vars/all.yml` is the single Elastic pin.** Roll
  out ES → Kibana → Fleet → agents; Elasticsearch cannot be downgraded. Check
  the images are actually on `docker.elastic.co` first — the artifacts API
  lists builds days earlier.

## Toolchain & how to run things

mise pins every tool (`mise.toml`) and provides every entry point. Nothing is
installed by hand and there is no Makefile.

```bash
mise run lint                 # pre-commit on all files + ansible-lint + syntax-check
mise run lint:ansible         # just the Ansible half
mise run tf:validate          # fmt + validate, no backend, no credentials
mise run inventory            # merged inventory graph, no credentials
mise run secrets:check        # names missing keys; never prints values
```

These need credentials and are for the human (ask first):
`mise run tf:plan`, `mise run tf:apply`, `mise run play <playbook> [args]`.

- ansible-lint must pass at the **production** profile (`ansible/.ansible-lint`).
- `colac.homelab` resolves only after `mise run setup` (or `deps:dev`, which
  installs the sibling core checkout instead of the pinned tag).
- Pins are load-bearing and shared with the other two repos: Terraform
  `1.15.7`, Telmate/proxmox `3.0.2-rc07`, ansible-core `2.17.14`,
  community.general `<13`.

## Secrets — SOPS + age, decrypted per command

- **`secrets.yaml` IS committed** — SOPS ciphertext. Never add it to
  `.gitignore`; `.gitleaks.toml` allowlists it.
- **Never read, print, `cat`, `grep` or `sed` `secrets.yaml`, `mise.local.toml`,
  the age key, or any git-ignored `*.tfvars`. Never run `sops -d`, `sops
  decrypt` or `.mise/sops-exec` yourself.** Refer to secrets by key name only;
  `secrets.yaml.example` lists them, and `mise run secrets:check` tells you
  which are missing without revealing values.
- **Nothing is exported into the shell.** `.mise/sops-exec <profile> <cmd>`
  decrypts for one command and exports only that profile's names
  (`terraform` → `TF_VAR_pm_*`/`TF_TOKEN_*`; `ansible` → the UPPERCASE names
  `group_vars/` reads with `lookup('env', …)`, the only place they are
  consumed). Never reintroduce a literal secret into `group_vars` or a role
  default, and never paste one into a rendered `.ini` or `.env`.
- The `while read` decrypt loop in `sops-exec` is deliberate: `eval` would
  re-parse plaintext as shell and break values with spaces, quotes or `$`.
- **Generated Elastic material does NOT go in `secrets.yaml`.** The CA and
  node cert live in `ansible/.certs/`, Fleet tokens in
  `ansible/.secrets-cache/` — git-ignored machine state, recoverable by
  re-running the roles against an empty cluster.
- Adding a secret: add the key to `secrets.yaml.example`, the mapping to the
  right profile in `.mise/sops-exec` (`need` or `want`), the
  `lookup('env', …)` in `group_vars/`, and tell the human to set the value
  with `mise run secrets:edit`.

## Conventions

- **Conventional Commits** (commitlint + semantic-release). Never hand-edit
  `CHANGELOG.md` or bump versions. Commit only when asked; the human pushes.
- **Role variables are prefixed with the role name**, register names too
  (`_fleet_bootstrap_kibana`, `_elastic_preflight_max_map_count`). The ported
  `es_*` names live in `inventory/group_vars/`, which keeps them cross-role
  and the linter satisfied. Anything a role on host A needs to know about host
  B must live in `group_vars/`, because role defaults are not visible
  cross-host.
- Markdown: heading levels increment by one (MD001); fenced code blocks
  declare a language (MD040).
