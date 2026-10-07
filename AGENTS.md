# AGENTS.md — homelab-proxmox-monitoring

Instructions for AI coding agents working in this repo. Humans start at
[README.md](README.md). Read the linked doc before working in its area; the
rules below are the ones that must hold in every session.

## What this repo is

The monitoring layer of a three-repo Proxmox homelab: the Elastic Stack on
**one** VM (single-node Elasticsearch, Kibana, Fleet Server), Prometheus
exporters for TrueNAS and Nextcloud, and Elastic Agent enrollment on **every**
host — including hosts other repos own. Siblings in `~/git-repos/`:

- `homelab-proxmox` — core: templates, `base-vm`, the `colac.homelab`
  collection, and the homelab-wide docs
- `homelab-proxmox-workloads` — the apps (Nextcloud, k3s)

Changes to the template, the module, or `common`/`docker_data` belong in core:
propose them there, then bump the pin here. Nextcloud itself belongs in
workloads.

## Where to look

- [README.md](README.md) — architecture and the contracts with other repos
- [RUNBOOK.md](RUNBOOK.md) — from-zero deploy, TrueNAS setup, upgrades, operations
- [ansible/README.md](ansible/README.md) — roles, inventory, who owns which host
- [terraform/README.md](terraform/README.md) — VM sizing and inventory generation
- Core's docs (`../homelab-proxmox/docs/`): `CREDENTIALS.md` (issue, store,
  rotate every credential), `DEVELOPMENT.md` (tasks, conventions, releases),
  `ARCHITECTURE.md`
- [TODO.md](TODO.md) — status; check items off there, never in this file

## Commands

```bash
mise run lint            # pre-commit on all files + ansible-lint + syntax-check
mise run tf:validate     # no backend, no credentials
mise run inventory       # merged inventory, no credentials
mise run secrets:check   # missing key names only
```

Need credentials — ask the human first: `mise run tf:plan`, `mise run tf:apply`,
`mise run play <playbook> [args]`.

## Rules

- **Secrets:** never read, print, `cat`, `grep` or `sed` `secrets.yaml`,
  `mise.local.toml`, the age key, or `*.tfvars`; never run `sops -d`,
  `sops decrypt` or `.mise/sops-exec`. Refer to secrets by key name
  (`secrets.yaml.example`) and use `mise run secrets:check`. New secret → core's
  `docs/CREDENTIALS.md` § Adding a secret.
- **Generated Elastic material is not a secret to manage:** `ansible/.certs/`
  and `ansible/.secrets-cache/` are git-ignored machine state. Never move them
  into `secrets.yaml` or commit them.
- **Git:** Conventional Commits; never edit `CHANGELOG.md` or version numbers;
  commit only when asked; the human pushes.
- **Ansible:** ansible-lint stays green at the production profile; role
  variables and `register:` names carry the role prefix. Anything a role on
  host A needs about host B goes in `inventory/group_vars/`.

## Deliberate decisions — do not "fix"

- **One VM.** The six-VM version lives in `homelab-proxmox-elastic`. If a
  change needs a second monitoring VM, it belongs there — never grow this one
  into a cluster.
- **The ported Elastic roles keep their comments.** They record bugs found only
  on live runs (Fleet's output defaulting to `localhost:9200`,
  `ELASTIC_PASSWORD_FILE` crash-looping at mode 644, Kibana needing
  whitespace-free JSON for `elasticsearch.hosts`, `force_basic_auth` against
  Kibana's API). Do not tidy them away.
- **Configure only this repo's host.** `00-bootstrap.yml` targets `monitoring`;
  hosts in `agents` (`inventory/hosts.yml`) get only the CA (`20`) and the agent
  (`50`). Never touch another repo's VM beyond that.
- **The ES OS prerequisites are core's template's.** `elastic_preflight` only
  verifies them; never add a sysctl task here.
- **The monitoring host is in three groups** (`monitoring`, `elasticsearch`,
  `kibana`), so the ported roles keep `groups['elasticsearch'][0]`.
- **Replicas are zero** via the `*@custom` component templates — single node.
- **Fleet package-policy input keys are verified, never guessed** — e.g.
  `prometheus-prometheus/metrics`, checked against
  `epr.elastic.co/package/prometheus/<version>/`.
- **`kibana_fqdn` is derived** (`kibana.` + the zone of `nextcloud_domain`), so
  the real domain never appears in the repo. Ansible talks to Kibana on
  `127.0.0.1` with `validate_certs: false`; the Let's Encrypt cert is for
  browsers only.
- **`stack_version` in `group_vars/all.yml` is the single Elastic pin.** Roll
  out ES → Kibana → Fleet → agents; Elasticsearch never downgrades. Check the
  images exist on `docker.elastic.co` first.
- **TrueNAS pushes Graphite; it is not scraped**, and its
  `/etc/netdata/netdata.conf` is a manual step a TrueNAS update undoes.
