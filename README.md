# Homelab Proxmox — Monitoring

The **observability layer** of the homelab: the Elastic Stack on one Proxmox
VM (single-node Elasticsearch, Kibana and Fleet Server), a Fleet-managed
Elastic Agent on every host, and Prometheus exporters for what Elastic has no
integration for (TrueNAS, Nextcloud's application metrics).

One of three repos, each owning one layer:

| Repo | Layer | Owns |
|---|---|---|
| [homelab-proxmox](https://github.com/colac/homelab-proxmox) | **core** | Packer templates, the `base-vm` Terraform module, the `colac.homelab` Ansible collection, homelab-wide architecture |
| **homelab-proxmox-monitoring** (this) | **monitoring** | The monitoring VM, the Elastic Stack, agent enrollment on every host |
| [homelab-proxmox-workloads](https://github.com/colac/homelab-proxmox-workloads) | **workloads** | The apps: Nextcloud now, k3s next |

The homelab-wide picture — how the layers fit, what each publishes and
consumes — is in the core repo's
[docs/ARCHITECTURE.md](https://github.com/colac/homelab-proxmox/blob/main/docs/ARCHITECTURE.md).

- **Deploying it from zero?** [RUNBOOK.md](RUNBOOK.md).
- **Working on the roles?** [ansible/README.md](ansible/README.md).
- **Resizing the VM?** [terraform/README.md](terraform/README.md).
- **What is done and what is not?** [TODO.md](TODO.md).

## Architecture

```mermaid
flowchart LR
  subgraph core["core repo (pinned tags)"]
    tpl["Packer template<br/>ubuntu-26.04-template"]
    mod["base-vm module"]
    col["colac.homelab<br/>common · docker_data"]
  end

  subgraph mon["monitoring VM — this repo"]
    es[("Elasticsearch<br/>1 node :9200")]
    kb["Kibana :443<br/>Let's Encrypt"]
    fs["Fleet Server :8220"]
    ex["exporters (loopback)<br/>graphite · nextcloud · pve(off)"]
    ag0["Elastic Agent<br/>monitoring policy"]
  end

  subgraph wl["owned by the workloads repo"]
    nc["Nextcloud VM<br/>Elastic Agent<br/>homelab policy"]
  end

  nas["TrueNAS<br/>netdata"]
  you(["you"])

  tpl -. cloned by .-> mon
  mod -. terraform/ .-> mon
  col -. 00-bootstrap .-> mon

  nc -- "enroll · metrics · logs" --> fs
  ag0 --> fs
  fs --> es
  kb --> es
  ag0 -- scrape --> ex
  ex -- serverinfo API --> nc
  nas -- "graphite :9109" --> ex
  you -- "https://kibana.&lt;zone&gt;" --> kb
```

| Path | How | Why |
|---|---|---|
| Every VM | Elastic Agent, Fleet-managed, System + Docker integrations | Policy is pushed from Kibana, so adding an integration is not a playbook change |
| TrueNAS | Reporting Exporter → Graphite → `graphite_exporter` → agent's Prometheus integration | Not Ansible-managed, cannot take an agent |
| Nextcloud app metrics | `nextcloud-exporter` → Prometheus integration | Elastic ships no integration for it |
| Proxmox host | `prometheus-pve-exporter` | Scaffolded, off — see [TODO.md](TODO.md) |

**Why one VM:** the six-VM version lives in `homelab-proxmox-elastic`; that
topology is more than the 32 GB mini-PC has spare alongside Nextcloud. APM,
tracing and the OTel demo were given up to fit — full-text log search,
Fleet-managed agents and the path to OSQuery/Elastic Security were not.
**If a change needs a second monitoring VM, it belongs in that repo.**

### What this repo consumes, and what consumes it

| Contract | Direction | Where it is pinned |
|---|---|---|
| Template `ubuntu-26.04-template`, with the ES prerequisites baked in | core → here | `terraform/variables.tf` `template_name` |
| `base-vm` module | core → here | `terraform/main.tf` `?ref=v2.0.0` |
| `colac.homelab` collection | core → here | `ansible/requirements.yml` `version: v2.0.0` |
| Agent targets (the hosts to enroll) | workloads → here | `ansible/inventory/hosts.yml` (hand-authored) |
| `nextcloud_serverinfo_token` minted on the Nextcloud VM | workloads → here | this repo's `secrets.yaml` |
| DNS: `kibana.<zone>` → this VM | here → PiHole | set by hand in PiHole (see TODO) |

## Quick start

```bash
mise trust && mise install        # pinned tools (Terraform, sops, Python, …)
mise run setup                    # venv deps, collections, hooks
mise run secrets:edit             # fill secrets.yaml — keys in secrets.yaml.example
mise run secrets:check            # every key present? (prints names, never values)

mise run tf:plan && mise run tf:apply
cp ansible/inventory/hosts.yml.example ansible/inventory/hosts.yml   # agent targets
mise run play playbooks/site.yml
mise run play playbooks/99-healthcheck.yml
```

`mise tasks` lists everything. Arguments after a task name go straight to the
tool: `mise run play playbooks/35-kibana.yml --check --diff`.

## Secrets

**One encrypted file, decrypted per command, never into your shell.** Every
human-chosen credential this repo needs lives in `secrets.yaml`, SOPS-encrypted
with age and committed as ciphertext (`.gitleaks.toml` allowlists it;
`.gitignore` deliberately does not list it). `secrets.yaml.example` is the
readable key reference.

`.mise/sops-exec` is the only thing that decrypts it. Each task that needs
credentials runs its command through it, with a **profile** that exports only
what that tool reads:

| Profile | Used by | Exports |
|---|---|---|
| `terraform` | `mise run tf…` | `TF_VAR_pm_api_url`, `TF_VAR_pm_api_token_id`, `TF_VAR_pm_api_token_secret`, `TF_VAR_pm_tls_insecure`, `TF_TOKEN_app_terraform_io` (if set) |
| `ansible` | `mise run play` | `ELASTIC_PASSWORD`, `KIBANA_SYSTEM_PASSWORD`, `KIBANA_ENCRYPTION_KEY`, `NEXTCLOUD_DOMAIN`, `ACME_EMAIL`, `CLOUDFLARE_DNS_API_TOKEN`, `NEXTCLOUD_SERVERINFO_TOKEN`, `PVE_EXPORTER_TOKEN_*` |

So Terraform never sees an Elastic password, Ansible never sees the Proxmox
token, and nothing lingers in the shell — for you or for an agent working in
the repo. A bare `terraform plan` or `ansible-playbook` gets no credentials,
by design.

What stays out of git entirely:

| Path | Why |
|---|---|
| `~/.config/sops/age/keys.txt` | The age **private** key. Everything else is recoverable; this is not. |
| `ansible/inventory/monitoring.yml` | VM address, generated by Terraform |
| `ansible/inventory/hosts.yml` | Agent target addresses, hand-authored |
| `ansible/.certs/` | Internal Elastic CA, node certificate and key — generated |
| `ansible/.secrets-cache/` | Fleet service token and enrollment API keys — minted by the API |
| `mise.local.toml` | Per-machine overrides |

The last two Elastic paths are machine state, not human choices: losing them
is recoverable (the roles regenerate them against an empty cluster), so
round-tripping them through `secrets.yaml` would add risk without control.

## Conventions

- **Conventional Commits**, enforced by commitlint. Versioning and
  `CHANGELOG.md` are automated by semantic-release — never hand-edit either.
- **pre-commit** on every commit: `terraform_docs`, `terraform_fmt`,
  `markdownlint`, `shellcheck`, commitlint. `mise run lint` runs them all plus
  ansible-lint.
- **ansible-lint must pass at the production profile.** Role variables are
  prefixed with the role name.
- **Pins are load-bearing:** Terraform `1.15.7`, Telmate/proxmox
  `3.0.2-rc07`, ansible-core `2.17.14` — the same as the other two repos.
