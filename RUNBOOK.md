# Monitoring — the Elastic Stack on one VM

End-to-end runbook for the observability deployment: single-node
Elasticsearch, Kibana and Fleet Server, plus a Fleet-managed Elastic Agent on
every host. Sibling of [NEXTCLOUD.md](NEXTCLOUD.md); the same
Packer → Terraform → Ansible pipeline produces both.

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

**The Packer template must be rebuilt before this can run.** Elasticsearch
performs a hard bootstrap check on `vm.max_map_count` and refuses to start
below 262144; the template did not set it. That setting, the memlock/nofile
limits and the `/opt/elastic` directory are now baked into
`packer/ubuntu-24.04`, matching how the six-VM repo does it — the OS arrives
ready and Ansible has no involvement in host configuration. The same rebuild
swaps Grafana Alloy out for the Elastic Agent package.

```bash
cd packer/ubuntu-24.04
packer validate .
packer build .
```

The existing Nextcloud VM does **not** need re-cloning. It keeps running on
the old image; the `elastic_agent` role installs the agent package on it and
stops the leftover Alloy service. Only the monitoring VM needs the new
template, because only it runs Elasticsearch.

Also needed:

- Terraform Cloud workspace **`Monitoring`** in org `colac_homelab`,
  Execution Mode **Local**.
- The Elastic entries filled in in the repo-root `secrets.yaml`
  (`sops secrets.yaml`) — see `secrets.yaml.example` and the "Secrets" section
  below.
- `direnv` active in your shell, so those values reach Terraform and Ansible as
  environment variables. `make direnv-allow` if it reports a blocked `.envrc`.

## 1. Provision the VM

```bash
cd terraform/projects/monitoring   # direnv exports TF_VAR_pm_api_* on the way in
terraform init
terraform plan
terraform apply
```

This writes `ansible/inventory/monitoring.yml`, putting the single host into
the `monitoring`, `elasticsearch` and `kibana` groups at once — it genuinely
plays all three roles, and keeping the group names identical to the six-VM
repo's is what let the roles port across unchanged.

If `apply` reports the `guest_agent_reported_an_ip` check warning, the guest
agent had not answered yet — wait for the VM to boot and re-run.

## 2. Fill in the secrets

```bash
sops secrets.yaml        # from the repo root; re-encrypts on save
```

Four values (see `secrets.yaml.example` for the full comments):

```bash
openssl rand -hex 32     # kibana_encryption_key
```

- `elastic_password` — the `elastic` superuser; also your Kibana login.
- `kibana_system_password` — Kibana's own least-privilege ES account.
- `kibana_encryption_key` — Fleet encrypts its stored service tokens with this.
  `POST /api/fleet/setup` fails outright without it.
- `nextcloud_serverinfo_token` — generate on the Nextcloud VM:

```bash
ssh ubuntu@<nextcloud-ip>
sudo docker exec -u www-data nextcloud-aio-nextcloud \
  php occ config:app:set serverinfo token --value "$(openssl rand -hex 32)"
sudo docker exec -u www-data nextcloud-aio-nextcloud \
  php occ config:app:get serverinfo token   # copy into secrets.yaml
```

## 3. Deploy

```bash
cd ansible               # direnv exports the credentials and puts .venv/bin on PATH
ansible-playbook playbooks/site.yml
```

That runs the whole homelab, Nextcloud included. The order is load-bearing:
certificates before Elasticsearch (it will not start without them),
Elasticsearch before Kibana, Kibana before Fleet Server (which needs a service
token minted through it), Fleet Server before the agents (which have nothing
to enroll against otherwise).

To do just the monitoring half — this leaves the live Nextcloud VM alone:

```bash
ansible-playbook playbooks/00-bootstrap.yml --limit monitoring --check --diff
ansible-playbook playbooks/00-bootstrap.yml --limit monitoring
ansible-playbook playbooks/20-elastic-certs.yml \
                 playbooks/25-elasticsearch.yml \
                 playbooks/30-elasticsearch-security.yml \
                 playbooks/35-kibana.yml \
                 playbooks/40-fleet-server.yml \
                 playbooks/45-exporters.yml \
                 playbooks/50-elastic-agent.yml
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
`cloudflare_dns_api_token` Caddy uses for Nextcloud, and Kibana serves it on
443. certbot's own systemd timer renews it, and the deploy-hook it registered
copies the new pair in and restarts the container — no cron entry, nothing to
re-run. If renewal fails because the Cloudflare token changed or expired,
see [Rotating the Cloudflare API token](NEXTCLOUD.md#rotating-the-cloudflare-api-token-or-a-cert-failed-to-renew).

**The A record is yours to set, once, in PiHole** (Local DNS → DNS Records):
`kibana_fqdn` → the monitoring VM's IP (`terraform output vm_ip`). Issuance
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
`playbooks/25-elasticsearch.yml`. `cluster.initial_master_nodes` is a
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
cd ansible
ansible-playbook playbooks/99-healthcheck.yml
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

1. Create a **read-only** API token on the Proxmox host. `PVEAuditor` is the
   whole security boundary: even if the monitoring VM were compromised, this
   token cannot change anything on the hypervisor.

   ```bash
   # on the Proxmox host
   pveum user add pve-exporter@pve --comment "Read-only Prometheus exporter"
   pveum aclmod / -user pve-exporter@pve -role PVEAuditor
   pveum user token add pve-exporter@pve monitoring --privsep 0
   ```

2. Put the printed secret in `secrets.yaml` as `pve_exporter_token_secret`, and
   confirm `pve_exporter_token_id` matches `pve-exporter@pve!monitoring`.
3. Set `exporters_pve_enabled: true` and `exporters_pve_target` to the
   Proxmox host's LAN address.
4. Re-run `playbooks/45-exporters.yml`.

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
[TrueNAS/README.md](TrueNAS/README.md), Tier 1) and remain the thing that must
not be turned off.

## Secrets

Human-chosen secrets live in the repo-root `secrets.yaml`, SOPS-encrypted with
age and **committed as ciphertext**; `ansible/.envrc` exports them and
`inventory/group_vars/` reads them back with `lookup('env', …)`. Everything the
stack generates itself is cached controller-locally instead, outside git:

| Path | Holds | Why there |
|---|---|---|
| `secrets.yaml` | `elastic_password`, `kibana_system_password`, `kibana_encryption_key`, `nextcloud_serverinfo_token`, PVE token, plus `cloudflare_dns_api_token` / `reverse_proxy_acme_email` shared with Nextcloud | Human-chosen |
| `ansible/.certs/` | Internal CA, node cert and key | Generated; regenerating against an empty cluster is the recovery path |
| `ansible/.secrets-cache/` | Fleet service token, enrollment API keys | Minted by the API, not chosen |

Losing the caches is recoverable — the roles regenerate them. Committing them
would not be. See [Secrets](README.md#secrets) for the full scheme.

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
bump `elastic_agent_version` in both `packer/*/variables.pkr.hcl` (and the
fallback in `scripts/30-install-elastic-agent.sh`) so new templates match.

Roll it out in Elastic's required order: Elasticsearch, then Kibana, then Fleet
Server, then the agents. Kibana refuses to start against an older
Elasticsearch, and agents must not be newer than Fleet Server:

```bash
ansible-playbook playbooks/25-elasticsearch.yml
ansible-playbook playbooks/35-kibana.yml
ansible-playbook playbooks/40-fleet-server.yml
ansible-playbook playbooks/50-elastic-agent.yml      # every host, Nextcloud's too
ansible-playbook playbooks/99-healthcheck.yml
```

Each playbook re-renders the compose `.env`, and Compose pulls and recreates
only the container whose image changed. **Elasticsearch cannot be downgraded.**
Once it has started on the new version, its data is upgraded in place, so a
bad release is fixed by moving forward, not by reverting the pin. Afterwards,
`sudo docker image prune -a -f` on the VM removes the old images.

### Root filesystem full (apt fails with "No space left on device")

The usual cause is images on the OS disk: Docker's containerd image store
keeps them in `/var/lib/containerd`, and a VM bootstrapped before
`docker_data` handled that has it on the 12G root. Confirm on the VM:

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
ansible-playbook playbooks/00-bootstrap.yml --limit monitoring-vm --check --diff
ansible-playbook playbooks/00-bootstrap.yml --limit monitoring-vm
```

Then `df -h /` should be down to about 60%, and `docker ps` should show
every container up. If `/` is still full, the next largest is usually
`/var/lib/elastic-agent` (about 1G, normal) — grow root from the free
extents in `ubuntu-vg` rather than deleting from it
(see [packer/README.md](packer/README.md)).
