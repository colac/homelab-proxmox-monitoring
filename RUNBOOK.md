# Monitoring — the Elastic Stack on one VM

End-to-end runbook for the observability deployment: single-node
Elasticsearch, Kibana and Fleet Server, plus a Fleet-managed Elastic Agent on
every host — including hosts other repos own, such as the Nextcloud VM. The
template comes from the core repo (`homelab-proxmox`), the VM from this repo's
Terraform, everything inside it from this repo's Ansible.

## Why one VM

There is a six-VM version of this stack in a separate repo,
`homelab-proxmox-elastic`: three Elasticsearch nodes, Kibana with Fleet
Server, an APM server and an OpenTelemetry demo. It works, and it is the
better teaching artefact — but on a 32 GB mini-PC that also runs Nextcloud
(8 GB) and PiHole, six VMs is more than there is to spare.

This deployment is the same stack with the topology collapsed onto one
machine. Roughly 12 GB and six VMs become 8 GB and one.

| | Six-VM repo | This one |
|---|---|---|
| Elasticsearch | 3 nodes, real cluster | 1 node |
| Kibana | Own VM, Let's Encrypt cert | Same VM, Let's Encrypt cert (same role) |
| Fleet Server | Own listener on the Kibana VM | Same VM |
| APM / tracing | Yes, plus an OTel demo app | **No** |
| Cluster health | green | **yellow-then-green**, see below |
| Agents | 6, Fleet-managed | 2, Fleet-managed |

Most of the role code is ported directly from that repo, including the
comments recording bugs that only surfaced on a live run. **If a change here
needs a second VM, it belongs in that repo instead.**

## Architecture

```text
┌────────────────────────────────────────────────────────────────────┐
│ LAN 192.168.1.0/24                                                 │
│                                                                    │
│  ┌──────────────────┐            ┌───────────────────────────────┐ │
│  │ nextcloud VM     │  enrolled  │ monitoring VM                 │ │
│  │  elastic-agent ──┼───────────▶│  fleet-server   :8220         │ │
│  │  (System+Docker) │  metrics   │  elasticsearch  :9200 (1 node)│ │
│  └──────────────────┘  + logs    │  kibana          :443 ◀── you  │ │
│           ▲                      │                               │ │
│           │ serverinfo API       │  elastic-agent (host package) │ │
│           └──────────────────────┼─ scrapes, over loopback only: │ │
│                                  │   graphite-exporter    :9108  │ │
│  ┌──────────────────┐  graphite  │   nextcloud-exporter   :9205  │ │
│  │ TrueNAS          │───────────▶│   pve-exporter :9221 (off)    │ │
│  │  netdata         │   :9109    │                               │ │
│  └──────────────────┘            └───────────────────────────────┘ │
│                                                                    │
│  ┌──────────────────┐                                              │
│  │ Proxmox host     │  ◀── next step: pve-exporter polls its API   │
│  └──────────────────┘                                              │
└────────────────────────────────────────────────────────────────────┘
```

Three ingestion paths, and the reason for each:

- **Elastic Agent, Fleet-managed.** Every VM runs one. Policy is pushed from
  Kibana rather than configured per host, so adding an integration is a
  Kibana change, not a playbook change. The System and Docker integrations
  cover OS metrics, container metrics and logs.
- **Prometheus exporters, scraped by the agent.** Elastic ships no
  integration for TrueNAS or for Nextcloud's application metrics, so those
  arrive as Prometheus metrics through the agent's Prometheus integration in
  collector mode. The exporters bind to `127.0.0.1` — the agent runs on the
  host as a deb package, so it reaches them over loopback and nothing on the
  LAN can.
- **TrueNAS pushes Graphite.** It is not Ansible-managed and cannot take an
  agent, so its built-in Reporting Exporter speaks the Graphite line protocol
  to `graphite_exporter`, which translates.

## What is watched

| Target | How | Status |
|---|---|---|
| Nextcloud VM — CPU, RAM, disk, containers, logs | Elastic Agent, System + Docker integrations | Live |
| Nextcloud app — users, shares, apps, free space | `nextcloud-exporter` → Prometheus integration | Live |
| TrueNAS — pools, disks, ZFS, network, sensors | TrueNAS Reporting Exporter → `graphite_exporter` → Prometheus integration | Live |
| Monitoring VM itself | Elastic Agent (it watches itself) | Live |
| **Proxmox host** — node CPU/RAM, guest states, storage | `prometheus-pve-exporter` | **Scaffolded, off** |
| Uptime / TLS expiry probes | Elastic Synthetics | **Not yet** — see TODO.md |

## Prerequisites

**The VM must be cloned from a template that carries the Elasticsearch
prerequisites.** Elasticsearch performs a hard bootstrap check on
`vm.max_map_count` and refuses to start below 262144. That setting, the
memlock/nofile limits and the `/opt/elastic` directory are baked into the core
repo's Packer templates, matching how the six-VM repo does it — the OS arrives
ready and Ansible only *verifies* it (`elastic_preflight`). If the template
predates them, rebuild it in the core repo:

```bash
cd ../homelab-proxmox
mise run packer:build 26.04       # the template_name terraform/ clones
```

The existing Nextcloud VM does **not** need re-cloning. It keeps running on
the old image; the `elastic_agent` role installs the agent package on it and
stops the leftover Alloy service. Only the monitoring VM needs the new
template, because only it runs Elasticsearch.

Also needed:

- Terraform Cloud workspace **`Monitoring`** in org `colac_homelab`,
  Execution Mode **Local**.
- This repo's `secrets.yaml` filled in (`mise run secrets:edit`) — see
  `secrets.yaml.example` and the "Secrets" section below.
  `mise run secrets:check` confirms every key is there without printing any.
- `mise install && mise run setup` done once, which also installs the pinned
  `colac.homelab` collection from the core repo.

## 1. Provision the VM

```bash
mise run tf:plan       # init + plan, with the Proxmox token for this command only
mise run tf:apply
```

This writes `ansible/inventory/monitoring.yml`, putting the single host into
the `monitoring`, `elasticsearch` and `kibana` groups at once — it genuinely
plays all three roles, and keeping the group names identical to the six-VM
repo's is what let the roles port across unchanged.

If `apply` reports the `guest_agent_reported_an_ip` check warning, the guest
agent had not answered yet — wait for the VM to boot and re-run.

## 2. Fill in the secrets

Every key in `secrets.yaml.example` — the Proxmox and Terraform Cloud tokens,
the three Elastic values, Kibana's Cloudflare token and ACME email,
`nextcloud_domain`, and the Nextcloud serverinfo token (minted on the Nextcloud
VM, so it needs Nextcloud running first). How to issue each:
[CREDENTIALS.md](https://github.com/colac/homelab-proxmox/blob/main/docs/CREDENTIALS.md).

```bash
mise run secrets:edit    # decrypts into VS Code, re-encrypts on save
mise run secrets:check   # names anything missing; never prints a value
```

## 3. Deploy

Agent targets other repos own go in `ansible/inventory/hosts.yml` (copy
`hosts.yml.example`) — today the Nextcloud VM. Then:

```bash
mise run inventory       # monitoring-vm in monitoring/elasticsearch/kibana; agents listed
mise run play playbooks/site.yml
```

That deploys the stack and enrolls every agent target. It never prepares
another repo's host: `00-bootstrap.yml` targets `monitoring` only, and the
agent targets see just the CA distribution and the enrollment. The order is
load-bearing:
certificates before Elasticsearch (it will not start without them),
Elasticsearch before Kibana, Kibana before Fleet Server (which needs a service
token minted through it), Fleet Server before the agents (which have nothing
to enroll against otherwise).

To leave the agent targets alone entirely (no CA push, no enrollment):

```bash
mise run play playbooks/00-bootstrap.yml --check --diff
mise run play playbooks/site.yml --limit monitoring
```

The bootstrap dry run stops at the data disk on a fresh VM — `--check` cannot
simulate volume-group creation, and it says so. After the real run,
`findmnt /var/lib/docker` on the VM should show `docker--vg-docker--lv`, and
`findmnt /var/lib/containerd` the same volume with `[/containerd-root]`. If the
second is missing, pulled images fill the 12G root: see
[Root filesystem full](#root-filesystem-full-apt-fails-with-no-space-left-on-device).

Kibana is then at `https://kibana.<your zone>` (the `kibana_fqdn` in
`group_vars/monitoring.yml`), user `elastic`.

### Kibana's certificate

`35-kibana.yml` runs `kibana_tls` before `kibana`: certbot obtains a Let's
Encrypt certificate for `kibana_fqdn` over Cloudflare DNS-01, with the same
`cloudflare_dns_api_token` from this repo's `secrets.yaml` (its own token —
Caddy on the Nextcloud VM has a separate one), and Kibana serves it on 443.
certbot's own systemd timer renews it, and the deploy-hook it registered
copies the new pair in and restarts the container — no cron entry, nothing to
re-run. If renewal fails because the Cloudflare token changed or expired,
see [Cloudflare DNS tokens](https://github.com/colac/homelab-proxmox/blob/main/docs/CREDENTIALS.md#cloudflare-dns-tokens).

**The A record lives in the core repo**, in `pihole_local_records`
(`dns/ansible/inventory/group_vars/pihole.yml`, entry `kibana`) — if the VM's
IP (`mise run tf output vm_ip`) ever changes, update it there with a PR and
run `mise run dns:play playbooks/10-pihole.yml` in core
([DNS runbook](https://github.com/colac/homelab-proxmox/blob/main/dns/README.md)). Issuance
does not need it — DNS-01 only writes a TXT record in Cloudflare — but a
browser does, and a stale record pointing at an old VM looks exactly like
Kibana being down. `99-healthcheck.yml` checks the name from your machine with
certificate validation on, so it catches both.

`kibana_tls_letsencrypt: false` falls back to the internal CA's node
certificate on port 5601. Browsers then warn until the CA is trusted:

```bash
# the CA is cached on the controller after the first run
sudo cp ansible/.certs/ca.crt /usr/local/share/ca-certificates/homelab-elastic.crt
sudo update-ca-certificates
```

### After the first successful run

Set `es_bootstrap_cluster: false` in
`ansible/inventory/group_vars/monitoring.yml` and re-run
`mise run play playbooks/25-elasticsearch.yml`. `cluster.initial_master_nodes` is a
bootstrap-only setting; leaving it set is how a node can silently form a
second, separate cluster after a rebuild.

## 4. Point TrueNAS at the stack

TrueNAS is not Ansible-managed, so this is a one-time manual step — the same
category as the Tailscale route approval in the Nextcloud runbook.

### 4a. Restore netdata's metrics (25.04 and newer)

TrueNAS 25.04 cut most of netdata's default collectors, so the Graphite feed
carries only a fraction of what the mapping file expects:

```bash
scp ansible/files/truenas/netdata.conf truenas_admin@192.168.1.214:/tmp/
ssh truenas_admin@192.168.1.214
sudo cp /tmp/netdata.conf /etc/netdata/netdata.conf
sudo chown root:root /etc/netdata/netdata.conf
sudo systemctl restart netdata
```

> **A TrueNAS update overwrites this file.** If NAS metrics go blank after an
> upgrade, this is the first thing to re-apply. There is no way around it from
> this repo — TrueNAS owns `/etc`.

### 4b. Create the Reporting Exporter

In the TrueNAS UI: **Reporting → Exporters → Add**.

| Field | Value |
|---|---|
| Type | `GRAPHITE` |
| Enabled | ✅ |
| Destination IP | the monitoring VM's IP |
| Destination Port | `9109` |
| Prefix | `truenas` |
| Hostname | `truenas` |
| Update every | `60` (match `exporters_scrape_period`) |
| Send names instead of ids | leave blank (defaults to true) |

**Prefix must be `truenas`** and **Hostname must match
`exporters_truenas_instance`** in `inventory/group_vars/monitoring.yml` — the
mapping file keys off the prefix and turns the hostname into the instance
label.

## 5. Verify

```bash
mise run play playbooks/99-healthcheck.yml
```

It reports cluster health and node count, Kibana's status, every Fleet agent
that is not online, each exporter's state, and — separately — whether TrueNAS
has actually pushed anything. That last check exists because a
`graphite_exporter` with nothing configured on the TrueNAS side starts
perfectly happily and serves an empty metrics page.

### Yellow is not necessarily wrong

A single node has nowhere to place a replica shard, so any index that asks for
one sits at yellow forever. `es_security_bootstrap` sets
`number_of_replicas: 0` on the `logs@custom`, `metrics@custom`,
`synthetics@custom` and `traces@custom` component templates — the supported
override point that Fleet's own index templates already reference, so it
survives stack upgrades.

That only affects data streams created *after* it runs, which is why it runs
before Kibana and Fleet get a chance to create theirs. If health is yellow
after a first run, find the stragglers and roll them over:

```bash
curl -k -u elastic:$PASS 'https://<ip>:9200/_cat/indices?v&health=yellow'
```

## Dashboards

Unlike the Prometheus alternative, dashboards come with the integrations —
installing the System, Docker and Prometheus packages (which
`fleet_bootstrap` does) also installs their saved objects. Look in
**Kibana → Dashboards** for "[Metrics System]", "[Metrics Docker]" and the
Prometheus overview; **Observability → Infrastructure** gives a host view
with no setup at all.

Nothing custom is shipped in this repo yet. TrueNAS is the gap — its metrics
arrive under `prometheus.collector` with no dashboard built for them, so
that one needs building by hand in Kibana. Tracked in
[TODO.md](TODO.md).

## Alerting

Kibana's built-in alerting (**Observability → Alerts → Manage rules**).
Nothing is configured out of the box. The three worth having first:

1. An agent stops reporting — Fleet shows it offline; a metric-threshold rule
   on `system.cpu` document count catches the same thing.
2. Nextcloud or TrueNAS free space crossing a threshold.
3. Pool health from the TrueNAS metrics.

## Proxmox host (the next step)

Scaffolded but off — `exporters_pve_enabled: false` in
`inventory/group_vars/monitoring.yml`. To turn it on:

1. Issue the read-only `pve-exporter@pve` token and store it as
   `pve_exporter_token_id` / `pve_exporter_token_secret` — see
   [Proxmox exporter token](https://github.com/colac/homelab-proxmox/blob/main/docs/CREDENTIALS.md#proxmox-exporter-token). `PVEAuditor` is the
   whole security boundary: even a compromised monitoring VM cannot change the
   hypervisor with it.
2. `mise run secrets:check` — the `ansible` profile then stops listing the two
   keys as empty.
3. Set `exporters_pve_enabled: true` and `exporters_pve_target` to the
   Proxmox host's LAN address.
4. `mise run play playbooks/45-exporters.yml`.

> **One extra step is needed and is not yet written.** `pve-exporter` is a
> multi-target exporter: it is scraped at `/pve?target=<host>`, not
> `/metrics`, so it needs its own Prometheus package policy with the
> `metrics_path` and `query` vars set — the shared one in `fleet_bootstrap`
> covers only the plain `/metrics` exporters. The Prometheus integration does
> expose a `query` var for exactly this, but the serialisation it expects was
> not verified against a live API, so it is deliberately not guessed at here.
> Adding that package policy by hand in Kibana once, then reading back what it
> produced, is the low-risk way to settle it.

## NAS hardware, beyond the pool

The Graphite feed already carries disk I/O, temperature, ZFS ARC and pool
capacity — most of what "monitor the NAS hardware" means in practice. What it
does not carry is **SMART attributes** (reallocated and pending sector
counts), which is what predicts a disk failure before the pool degrades.
TrueNAS's own email alerts cover that today (see
the core repo's [TrueNAS/README.md](https://github.com/colac/homelab-proxmox/blob/main/TrueNAS/README.md), Tier 1) and remain the thing that must
not be turned off.

## Secrets

Human-chosen secrets live in this repo's `secrets.yaml`, decrypted per command
by `.mise/sops-exec` — issuing and rotating each one is in core's
[CREDENTIALS.md](https://github.com/colac/homelab-proxmox/blob/main/docs/CREDENTIALS.md). What the stack generates itself is cached
controller-locally instead, outside git:

| Path | Holds | If lost |
|---|---|---|
| `ansible/.certs/` | Internal CA, node cert and key | Regenerated by `es_certs` against an empty cluster |
| `ansible/.secrets-cache/` | Fleet service token, enrollment API keys | Minted again by `fleet_bootstrap` |

Committing either would not be recoverable; losing them is.

## Operating notes

Three separate Compose projects on the VM, not one:

```bash
ssh ubuntu@<monitoring-ip>
sudo docker compose -f /opt/elastic/elasticsearch/docker-compose.yml ps
sudo docker compose -f /opt/elastic/kibana/docker-compose.yml logs -f
sudo docker compose -f /opt/elastic/fleet-server/docker-compose.yml ps
sudo docker compose -f /opt/exporters/compose.yaml ps
```

The Elastic Agent is a host package, not a container:

```bash
sudo systemctl status elastic-agent
sudo elastic-agent status
```

Do not edit the files under `/opt` — they are rendered by Ansible and
overwritten on the next run. Edit the role templates instead.

Disk is what runs out first. There is no retention policy configured yet: the
Fleet integrations ship with ILM policies that roll over but never delete.
Watch `/var/lib/docker` on the VM and set an ILM delete phase before the
100 GB data disk fills.

### Upgrading the stack

`stack_version` in `ansible/inventory/group_vars/all.yml` is the single pin for
Elasticsearch, Kibana, Fleet Server and the Elastic Agent. Check a version is
actually published before using it
([release notes](https://www.elastic.co/docs/release-notes)). Elastic's version
index lists builds days before their images reach `docker.elastic.co`. Also
bump `elastic_agent_version` in the core repo's `packer/*/variables.pkr.hcl`
(and the fallback in `scripts/30-install-elastic-agent.sh`) so new templates
match — a separate change there; until it lands, the `elastic_agent` role
simply reinstalls the newer package on each host.

Roll it out in Elastic's required order: Elasticsearch, then Kibana, then Fleet
Server, then the agents. Kibana refuses to start against an older
Elasticsearch, and agents must not be newer than Fleet Server:

```bash
mise run play playbooks/25-elasticsearch.yml
mise run play playbooks/35-kibana.yml
mise run play playbooks/40-fleet-server.yml
mise run play playbooks/50-elastic-agent.yml      # every host, Nextcloud's too
mise run play playbooks/99-healthcheck.yml
```

Each playbook re-renders the compose `.env`, and Compose pulls and recreates
only the container whose image changed. **Elasticsearch cannot be downgraded.**
Once it has started on the new version, its data is upgraded in place, so a
bad release is fixed by moving forward, not by reverting the pin. Afterwards,
`sudo docker image prune -a -f` on the VM removes the old images.

### Root filesystem full (apt fails with "No space left on device")

The usual cause is images on the OS disk: Docker's containerd image store
keeps them in `/var/lib/containerd`, and a VM bootstrapped before
`colac.homelab.docker_data` handled that has it on the 12G root. Confirm on the VM:

```bash
df -h /                                   # 100%
sudo du -xsh /var/lib/containerd          # several GB
findmnt /var/lib/containerd               # nothing: not on the data disk
```

Re-run the bootstrap for that host only. It stops Docker (so Elasticsearch,
Kibana and Fleet Server go down for the copy, a minute or two), moves
containerd's root onto the data disk, deletes the OS-disk copy, and starts
everything again:

```bash
mise run play playbooks/00-bootstrap.yml --check --diff
mise run play playbooks/00-bootstrap.yml
```

Then `df -h /` should be down to about 60%, and `docker ps` should show
every container up. If `/` is still full, the next largest is usually
`/var/lib/elastic-agent` (about 1G, normal) — grow root from the free
extents in `ubuntu-vg` rather than deleting from it
(see the core repo's [packer/README.md](https://github.com/colac/homelab-proxmox/blob/main/packer/README.md)).
