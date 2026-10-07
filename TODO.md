# TODO / Roadmap

The single place this repo's status lives. When something lands, check it off
here — `README.md` and `AGENTS.md` point at this file rather than duplicating
status inline. Homelab-wide and template items are tracked in the core repo's
`TODO.md`; Nextcloud and k3s in the workloads repo's.

Roughly in dependency order within each section.

## Monitoring

The Elastic Stack, with the six-VM topology from `homelab-proxmox-elastic`
collapsed onto one VM. See [RUNBOOK.md](RUNBOOK.md) for why, and for what was
given up (APM, tracing, the OTel demo).

- [x] Elasticsearch OS prerequisites baked into the core template
      (`vm.max_map_count`, memlock/nofile, `/opt/elastic`), and Grafana Alloy
      replaced by the Elastic Agent package, pre-installed but left disabled
- [x] Terraform → one 8 GB VM, TFC workspace `Monitoring`, generating
      `ansible/inventory/monitoring.yml` with the host in the `monitoring`,
      `elasticsearch` and `kibana` groups at once
- [x] `ansible/inventory/` as a directory inventory, so Terraform's fragment
      and the hand-authored agent targets never clobber each other
- [x] `es_certs`, `elasticsearch`, `es_security_bootstrap`, `kibana`,
      `fleet_bootstrap`, `fleet_server` and `elastic_agent` ported from the
      six-VM repo and simplified to single-node
- [x] Single-node zero-replica override on the `logs@custom`/`metrics@custom`
      component templates, so cluster health can actually reach green
- [x] Nextcloud and TrueNAS metrics via Prometheus exporters, scraped by the
      agent's Prometheus integration in collector mode — Elastic ships no
      integration for either
- [x] **A real certificate for Kibana.** `kibana_tls` ported from the six-VM
      repo: certbot + Cloudflare DNS-01 for `kibana.<zone>`, served on 443
- [ ] **Run it live.** Everything above is validated by rendering and linting,
      not by a real deployment. The six-VM repo's history is a list of bugs
      that only appeared on a live run; expect some here too
- [ ] **Proxmox host metrics.** `prometheus-pve-exporter` is in the exporters
      role but `exporters_pve_enabled` is `false`. Needs a read-only
      `PVEAuditor` token, *and* its own Prometheus package policy — it is a
      multi-target exporter scraped at `/pve?target=…`, so the shared
      `/metrics` package policy does not cover it. The Prometheus integration
      exposes a `query` var for this; the serialisation it expects was not
      verified against a live API and is deliberately not guessed at. See
      RUNBOOK.md's "Proxmox host" section
- [ ] **A TrueNAS dashboard.** NAS metrics arrive under
      `prometheus.collector` with no dashboard built for them. The upstream
      [Supporterino/truenas-graphite-to-prometheus](https://github.com/Supporterino/truenas-graphite-to-prometheus)
      dashboards are Grafana JSON and do not import into Kibana, so this one
      has to be built by hand
- [ ] **Uptime and TLS-expiry probes.** The Prometheus design used
      `blackbox_exporter`; the Elastic equivalent is Synthetics, which is the
      better tool (real browser checks) but needs a private location backed by
      a Fleet agent policy. Dropped rather than half-ported — nothing
      currently watches whether Nextcloud's certificate is about to expire
- [ ] **ILM retention.** The Fleet integrations ship ILM policies that roll
      over but never delete, so the 100 GB data disk (`data_disk_size`, not
      `disk0_size`) fills eventually. Needs a delete phase sized against real
      ingest, which means measuring first
- [ ] **Alerting rules.** Kibana alerting is available but nothing is
      configured. The three that matter first are in RUNBOOK.md
- [ ] **Watch DNS.** Core now runs Pi-hole as code: `pihole-ct` at
      `192.168.1.153` (live), and later a Raspberry Pi at `.53`. Nothing
      monitors either. Add them to `inventory/hosts.yml` as agent targets —
      the Elastic Agent in an unprivileged LXC needs checking first
- [ ] **OSQuery, Elastic Defend, Elastic Security.** The reason for choosing
      Elastic over Prometheus in the first place. All need Fleet working first

## Repo / tooling

- [x] **Split out of the homelab monorepo.** History for these paths kept via
      `git filter-repo`; the shared roles and module now come from core at a
      pinned tag; mise replaces the Makefile and direnv; `elastic_preflight`
      split from the old `common` role
- [x] **On core v2.0.1, plan clean.** Applied once: the inventory fragment is
      now written to `ansible/inventory/monitoring.yml` from `terraform/`, and
      the VM's CPU moved from the deprecated `cores` into the `cpu { }` block
      (same 4 cores, `host` type — no reboot). Plans say "No changes"
- [x] **Docs:** `AGENTS.md` imported by a one-line `CLAUDE.md`; credentials
      and development docs centralised in core's `docs/`; `mise run
      deps:dev` also points Terraform at the sibling core through a
      git-ignored `dev_override.tf`
- [ ] **Decommission the six-VM Elastic cluster.** `192.168.1.230`–`.235` are
      still running. `cd homelab-proxmox-elastic/terraform && terraform plan
      -destroy` first, and read the plan before confirming
- [ ] **A dedicated Proxmox token for this repo** (`terraform@pve!terraform-monitoring`)
      so revoking the workloads one cannot break this one
- [ ] **A read-only agent identity.** A separate age key and a
      `PVEAuditor`-only token an AI agent could use for `plan`/healthcheck,
      with `apply` and `play` kept for the human
- [ ] **Enable the commented-out pre-commit hooks.** `ansible-lint`,
      `yamllint` and `gitleaks` are configured but disabled in
      `.pre-commit-config.yaml`; `ansible-lint` passes at the production
      profile, so it can be turned on now
