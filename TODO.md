# TODO / Roadmap

The single place deployment status lives. When something lands, check it off
here — `README.md` and `CLAUDE.md` point at this file rather than duplicating
status inline, so they do not need editing too.

Roughly in dependency order within each track.

## Nextcloud

- [x] Packer base template (Ubuntu 24.04, Docker + Tailscale)
- [x] Terraform `projects/nextcloud` → one VM, TFC workspace `Nextcloud`
- [x] Nextcloud AIO in reverse-proxy mode behind Caddy, Let's Encrypt via
      Cloudflare DNS-01
- [x] TrueNAS SMB external storage: per-user private folders plus a read-only
      `Familia` mount
- [x] Tailscale subnet route + PiHole split-DNS for off-LAN reach
- [ ] Verify Nextcloud's own Borgbackup covers the database and app config,
      and document the restore path in `NEXTCLOUD.md` — the SMB external
      storage is explicitly **not** covered by it

## Monitoring

The Elastic Stack, with the six-VM topology from `homelab-proxmox-elastic`
collapsed onto one VM. See [MONITORING.md](MONITORING.md) for why, and for
what was given up (APM, tracing, the OTel demo).

- [x] Packer: Elasticsearch OS prerequisites baked into the template
      (`vm.max_map_count`, memlock/nofile, `/opt/elastic`), and Grafana Alloy
      replaced by the Elastic Agent package, pre-installed but left disabled
- [x] Terraform `projects/monitoring` → one 8 GB VM, TFC workspace
      `Monitoring`, generating `ansible/inventory/monitoring.yml` with the
      host in the `monitoring`, `elasticsearch` and `kibana` groups at once
- [x] `ansible/inventory/` converted to a directory inventory so each
      Terraform project owns a fragment and none clobbers another
- [x] `es_certs`, `elasticsearch`, `es_security_bootstrap`, `kibana`,
      `fleet_bootstrap`, `fleet_server` and `elastic_agent` ported from the
      six-VM repo and simplified to single-node
- [x] Single-node zero-replica override on the `logs@custom`/`metrics@custom`
      component templates, so cluster health can actually reach green
- [x] Nextcloud and TrueNAS metrics via Prometheus exporters, scraped by the
      agent's Prometheus integration in collector mode — Elastic ships no
      integration for either
- [ ] **Run it live.** Everything above is validated by rendering and linting,
      not by a real deployment. The six-VM repo's history is a list of bugs
      that only appeared on a live run; expect some here too. The first run
      is also the first exercise of the rebuilt Packer template
- [ ] **Proxmox host metrics.** `prometheus-pve-exporter` is in the exporters
      role but `exporters_pve_enabled` is `false`. Needs a read-only
      `PVEAuditor` token, *and* its own Prometheus package policy — it is a
      multi-target exporter scraped at `/pve?target=…`, so the shared
      `/metrics` package policy does not cover it. The Prometheus integration
      exposes a `query` var for this; the serialisation it expects was not
      verified against a live API and is deliberately not guessed at. See
      MONITORING.md's "Proxmox host" section
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
      over but never delete, so the 100 GB disk fills eventually. Needs a
      delete phase sized against real ingest, which means measuring first
- [x] **A real certificate for Kibana.** `kibana_tls` ported from the six-VM
      repo: certbot + Cloudflare DNS-01 for `kibana.<zone>`, served on 443,
      reusing the token Caddy already had
- [ ] **Alerting rules.** Kibana alerting is available but nothing is
      configured. The three that matter first are in MONITORING.md
- [ ] **PiHole.** Runs on the Proxmox host outside this repo and is not
      monitored. The owner has flagged it for redesign; folding it into the
      pipeline would also make it an agent target
- [ ] **OSQuery, Elastic Defend, Elastic Security.** The reason for choosing
      Elastic over Prometheus in the first place. All need Fleet working first

## k3s

- [x] Terraform `projects/k3s` → VM only
- [ ] Ansible role — nothing configures the VM yet

## Repo / tooling

- [x] `ansible/playbooks/` with numbered playbooks and a `site.yml` that
      imports them, and `group_vars/` moved under `inventory/` — the layout
      the six-VM repo uses, so one command redeploys the whole homelab
- [ ] **Decommission the six-VM Elastic cluster.** `192.168.1.230`–`.235` are
      still running. `cd homelab-proxmox-elastic/terraform && terraform plan
      -destroy` first, and read the plan before confirming
- [ ] **`sockets` deprecation in `modules/base-vm`.** `terraform validate`
      warns that `sockets = 1` should be `cpu { sockets = }`. Shared by both
      VM projects, so changing it touches the live Nextcloud VM's plan — worth
      doing deliberately, with a `plan` reviewed first, not as a drive-by
- [ ] **Enable the commented-out pre-commit hooks.** `ansible-lint`,
      `yamllint` and `gitleaks` are configured but disabled in
      `.pre-commit-config.yaml`. `ansible-lint` currently passes clean at the
      production profile, so it can be turned on now
- [x] **Ubuntu 26.04 base template.** `packer/ubuntu-26.04/` builds the same
      image on 26.04 LTS at VM ID 9001, so it sits alongside the 24.04
      template rather than replacing it. Docker and Tailscale both publish
      `resolute` repos and every autoinstall package still exists, so the
      provisioning scripts are unchanged
- [x] **Split OS and Docker data disks.** 24G LVM OS disk in the 26.04
      template; a second disk attached by `base-vm`'s `data_disk_size` and
      turned into `docker-vg` by the `docker_data` role, mounted at
      `/var/lib/docker`. k3s gets 12G, monitoring 100G (moved off `disk0_size`,
      because ES data is the `esdata` Docker volume). Nextcloud left alone
- [ ] **Reclaim the monitoring VM's ILM sizing against the data disk.** The
      retention item further up assumed `disk0_size`; the number that matters
      is now `data_disk_size`
- [ ] **Actually build and cut over to 26.04.** The 26.04 tree is validated by
      `packer validate` only — it has never been run against the ISO. The
      autoinstall's GRUB keystrokes, the reworked LVM storage config, and
      26.04's switch to `sudo-rs` and Rust `coreutils` are what a live build
      would test. Confirm with `lsblk` that `ubuntu-vg` actually exists —
      the 24.04 template silently produced none. Cutting over is
      then a `template_name` change in each of the three Terraform projects,
      one at a time, and a re-clone
- [ ] **Committed `.claude/settings.json`.** Added with this change; revisit
      the allow/ask/deny split once there is more experience running the
      monorepo end to end
