---
name: update
description: Update the monitoring VM with this repo's update procedure (OS packages, reboot) and prepare the pinned bumps — Elastic Stack (stack_version) and the exporters. Use when asked to update or reboot the monitoring VM or Elastic/Kibana, or when the homelab-update skill gets to monitoring.
---

# Update monitoring: the VM, the Elastic Stack, the exporters

The procedure is core's `colac.homelab.update` at this repo's pinned tag
(core's `docs/UPDATES.md`). The stack's upgrade order is in
[RUNBOOK.md § Upgrading the stack](../../../RUNBOOK.md#upgrading-the-stack).

## OS packages and reboots (no secrets)

Run as background jobs with the output in a scratchpad log, and give the user
the path to `tail -f`. Use `mise -C ~/git-repos/homelab-proxmox-monitoring run …`.

| Step | Command | Changes |
|---|---|---|
| Report | `mise run update` | Nothing. JSON in `ansible/reports/latest.json` |
| Apply | `mise run update:apply` | Snapshot, apt, health |
| Reboot | add `-e update_reboot=true` | Reboots when the kernel or a library needs it |

A failure stops the run and prints `qm rollback <vmid> <snapshot>`. Never roll
back yourself: show the user the failing task and the command.

## Pinned versions: a branch, then the user runs the plays

The report lists newer releases for the pins. Apply never changes them.

1. **Check before bumping.**
   - The images exist: `docker.elastic.co/elasticsearch/elasticsearch`,
     `kibana/kibana` and `elastic-agent/elastic-agent` at the version, plus the
     agent `.deb` on `artifacts.elastic.co`. Elastic lists versions days before
     the images exist.
   - Read the release notes and Elastic's security announcements
     (discuss.elastic.co, category Security Announcements). Say which
     advisories the bump fixes.
2. **Bump on a branch.** `stack_version` in `ansible/inventory/group_vars/all.yml`
   (Elasticsearch, Kibana, Fleet Server and every agent). Exporters:
   `exporters_*_image` in `ansible/inventory/group_vars/monitoring.yml`. Core's
   templates pin the agent too (`elastic_agent_version` in `packer/*/variables.pkr.hcl`
   and `scripts/30-install-elastic-agent.sh`), as a separate core branch. Then
   `mise run lint`.
3. **The user runs the plays.** They need credentials (`sops-exec`), so give
   the commands; never run them yourself. Elastic's order:

   ```bash
   mise run play playbooks/25-elasticsearch.yml
   mise run play playbooks/35-kibana.yml
   mise run play playbooks/40-fleet-server.yml
   mise run play playbooks/50-elastic-agent.yml
   mise run play playbooks/45-exporters.yml   # only if an exporter pin moved
   mise run play playbooks/99-healthcheck.yml
   ```

   Elasticsearch never downgrades. Once 9.x.y has started, fix forward.
4. **After the plays,** run `mise run update` again: the components should say
   `ok`. Commit only when the user asks (`chore(deps): bump Elastic Stack to …`).
