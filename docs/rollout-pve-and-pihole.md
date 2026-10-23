# Rollout: monitoring the Proxmox host and the Pi-hole

Status as of 2026-10-08. Run the steps in order. Each step is marked:

- **[you]** a command or click for you to run;
- **[code]** a change to these repos that has not been written yet.

What is already done, on branches you have not yet committed:

- core `feat/proxmox-host-config`: the Pi-hole container goes from 512 MB to
  1 GB, plus `proxmox/configure.sh` and `proxmox/backup.sh`;
- monitoring `feat/pihole-agent`: `pihole-ct` is in the `agents` group (your
  local `hosts.yml`, and `hosts.yml.example`).

## Why this design

Elastic has no Proxmox or Pi-hole integration, so nothing here adds an
exporter. Elastic's package registry for 9.5.4 was checked.

| Host | Collected by | What you get |
|---|---|---|
| Pi-hole container | Elastic Agent: System + Custom Logs (filestream) | Container metrics; every query and block from `/var/log/pihole/pihole.log`; FTL's own log |
| Proxmox node | Elastic Agent: System (+ journald if needed) | Host CPU, memory, disk, network; host logs |
| Proxmox guests and storage | Proxmox's built-in OpenTelemetry metric server, pushing to the OTLP receiver on the monitoring VM's agent | Per-VM, per-container and per-storage metrics, with no API token on the node |

Each host gets **its own Fleet policy**. The general `homelab-agents` policy
carries the Docker integration, which these hosts do not need. A separate
policy also keeps the hypervisor's agent minimal.

## Part A — the Pi-hole container (`pihole-ct`)

### A1 [you] Give the container 1 GB

```bash
cd ~/git-repos/homelab-proxmox
mise run dns:plan     # expect: 1 to change — memory and swap 512 → 1024, in place
mise run dns:apply
```

If the plan says **"forces replacement"**, stop: that would rebuild your only
resolver. Check on the node: `pct config 103 | grep -E '^(memory|swap)'`.

### A2 [done] A Fleet policy for DNS hosts

Written on `feat/pihole-agent`, but not yet run against Fleet. It contains:

- `group_vars/all.yml`: `dns_agents_policy_id: dns-agents-policy`, and one
  `fleet_agent_policies` table that both roles read.
- `fleet_bootstrap`:
  - Add the policy to `_fleet_bootstrap_agent_policies`, and give each policy
    its own package list. Today every policy gets System **and** Docker,
    because of the `product()` loop.
  - Add `filestream` to `_fleet_bootstrap_packages`.
  - Add a filestream package policy (`pihole-logs`) for
    `/var/log/pihole/pihole.log` and `/var/log/pihole/FTL.log`, written to the
    data stream `logs-pihole-default`. Its keys (`filestream-filestream`,
    stream `filestream.filestream`) were checked against the 2.5.1 manifest
    and Kibana 9.5's Fleet source.
- `elastic_agent`: choose the policy from a host variable
  (`elastic_agent_policy`) instead of today's monitoring-or-everything-else
  switch. Hosts without the variable keep `homelab-agents`.
- `hosts.yml` / `.example`: set `elastic_agent_policy: dns` on `pihole-ct`.

B3 is now one more entry in `fleet_agent_policies`.

### A3 [you] Create the policy in Fleet

```bash
cd ~/git-repos/homelab-proxmox-monitoring
mise run play playbooks/40-fleet-server.yml
```

`fleet_bootstrap` only creates what is missing, so re-running it is safe. It
also mints and caches the new policy's enrollment token.

### A4 [you] Install and enroll the agent

```bash
mise run play playbooks/20-elastic-certs.yml playbooks/50-elastic-agent.yml --limit pihole-ct
```

This is what happens:

1. Ansible connects over **SSH as `root@192.168.1.153`** with
   `~/.ssh/homelab-proxmox`. That is the key core's Terraform authorised, the
   same one `mise run dns:play` uses. No sudo is involved
   (`ansible_become: false`).
2. `20` copies the internal CA to `/opt/elastic/certs/ca.crt`.
3. `50` downloads the Elastic Agent `.deb` for `stack_version`, installs it,
   and enrolls it with Fleet at `https://192.168.1.87:8220`. Enrollment uses
   the IP address, so it does not depend on DNS.

If you enroll **before** A2/A3, the agent lands in `homelab-agents`. Move it
later in Kibana: Fleet → Agents → the host → Actions → *Assign to new policy*.
There's no need to re-enroll.

### A5 [you] Verify

- Kibana → Fleet → Agents: `pihole` is **Healthy** on its policy.
- `mise run play playbooks/99-healthcheck.yml` shows every agent online.
- Discover: `host.name : "pihole"` shows system metrics, and the data view
  `logs-pihole-*` shows Pi-hole's query and FTL log lines.

**Done 2026-10-08:** the agent runs healthy in the unprivileged container, on
`dns-agents-policy` (System metrics, System logs through journald, and
`pihole-logs`). Two log lines from it are expected, not faults:

- `add_docker_metadata: stopped retrying docker connection … 30s elapsed`
  (warn). The agent probes Docker by default, finds none, and gives up once
  per component at each start.
- `add_cloud_metadata: hosting provider type not detected` (info). It's not
  a cloud VM.

If it ever turns unhealthy, look inside the container: `pct enter 103`, then
`elastic-agent status` and `journalctl -u elastic-agent -n 100`.

### A6 Later — the Raspberry Pi (`pihole-pi`, .53)

It's the same as A4, with a different `hosts.yml` entry: its own user,
`ansible_become: true`, and `elastic_agent_policy: dns`. The role picks the
arm64 package automatically (`dpkg --print-architecture`).

## Part B — the Proxmox node (agent on the host)

### B1 [you] Let Ansible reach the node

```bash
ssh-copy-id -i ~/.ssh/homelab-proxmox.pub root@192.168.1.169
ssh -i ~/.ssh/homelab-proxmox root@192.168.1.169 true && echo ok
```

### B2 [you] Add the node to the inventory

In `ansible/inventory/hosts.yml`, under `agents`:

```yaml
        pve-node:
          ansible_host: 192.168.1.169
          ansible_user: root
          ansible_become: false
          elastic_agent_policy: pve      # once A2/B3 exist
```

Use `pve-node`, not `pve`: Ansible misbehaves when a host and a group share a
name.

### B3 [code] A Fleet policy for the hypervisor

Use the same mechanism as A2: a `pve-agents-policy` with **System only**. Add
the journald integration if the node keeps its logs only in the journal;
check with `ls /var/log/syslog` on the node. (On the Debian 13 Pi-hole
container, System 3.0.0 added a journald input by itself, so expect the same
here.) Don't add Osquery or Elastic
Defend to this policy unless you decide to on purpose. Fleet agents run as
root, so whoever administers Fleet can run what those integrations allow on
the hypervisor.

### B4 [you] Create the policy, then enroll

```bash
mise run play playbooks/40-fleet-server.yml
mise run play playbooks/20-elastic-certs.yml playbooks/50-elastic-agent.yml --limit pve-node
```

### B5 [you] Verify

As in A5, with `host.name : "pve"`.

## Part C — guest and storage metrics over OpenTelemetry

Proxmox VE 9.2 can push metrics over OpenTelemetry: Datacenter → Metric
Server → Add → **OpenTelemetry**, the entry in your screenshot. The receiving
end is the **OTLP Receiver** integration (`otlp_input_otel`). It needs
Kibana 9.4 or later and the Basic license, and Elastic marks it **beta /
technical preview**.

### C1 [you] Choose a bearer token

The receiver listens on the LAN, so require a token. Proxmox sends it as a
header.

```bash
openssl rand -hex 32
cd ~/git-repos/homelab-proxmox-monitoring && mise run secrets:edit   # add pve_otel_bearer_token
```

### C2 [code] Add the receiver to the monitoring VM's policy

- `secrets.yaml.example`, the env mapping and CREDENTIALS.md:
  `pve_otel_bearer_token`.
- `fleet_bootstrap`: install `otlp_input_otel`, then add a package policy to
  `monitoring-agent-policy`. These variables are verified against the 0.2.0
  package:
  - `http_endpoint: 0.0.0.0:4318` (the default `localhost:4318` would refuse
    the node);
  - `grpc_endpoint: localhost:4317` (unused);
  - `enable_bearer_auth: true`, `bearer_token: <secret>`.
- Not yet checked: whether Fleet's package lookup needs `prerelease=true` to
  see a beta package. Find out while writing this.

### C3 [you] Deploy the receiver and test it

```bash
mise run play playbooks/40-fleet-server.yml
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://192.168.1.87:4318/v1/metrics
```

Expect a refusal without the token, such as `401`, which shows authentication
is on. A connection error means it isn't listening on the LAN address.

### C4 [you] Point Proxmox at it

On the node, from core's `proxmox/` folder. `read -s` keeps the token out of
your shell history:

```bash
read -rs OTEL_BEARER_TOKEN && export OTEL_BEARER_TOKEN
OTEL_SERVER=192.168.1.87 ./configure.sh --check   # shows the metric-server change
OTEL_SERVER=192.168.1.87 ./configure.sh
```

Or use the UI: Server `192.168.1.87`, Port `4318`, Protocol **HTTP**.
Proxmox defaults to HTTPS with certificate checks, and the receiver is set up
here without TLS. Path `/v1/metrics`. The header is base64-encoded JSON:
`{"Authorization":"Bearer <token>"}`.

### C5 [you] Verify

- On the node: `journalctl -u pvestatd -f` shows no send errors.
- Kibana → Discover: metrics with the node's and guests' resource attributes.
  The data stream names are not documented yet, so note them here once you
  see them.

### C6 [code] Remove the pve-exporter scaffolding

Once C5 works, remove the following: `exporters_pve_*` in
`group_vars/monitoring.yml` and its role tasks, the *Proxmox exporter token*
section in core's CREDENTIALS.md, and `ENABLE_PVE_EXPORTER` in
`configure.sh`.

## Part D — Optional: alerts and uptime

- An alert on **agent offline** for `pihole` and `pve`. That is the only
  signal an agent can't send itself.
- **Synthetics** from the monitoring VM's agent (a private location): a TCP
  check on `192.168.1.153:53` and an HTTP check on `/admin`. The registry
  lists the package on the Basic license. There is **no DNS check type**, so
  this proves the server is reachable, not that it resolves names.

## When it's done

- Monitoring TODO: tick **Watch DNS** and add the Pi to it if it's still
  pending.
- Core `docs/ARCHITECTURE.md`: add both hosts to the runtime diagram, and add
  the OTLP push (node → monitoring `:4318`) to it.
- Monitoring README: in *what is collected from where*, replace the
  pve-exporter row with the agent and OpenTelemetry rows.
