# Proxmox Datacenter Metrics → InfluxDB

Proxmox can ship node and VM metrics to an external time-series database via
**Datacenter → Metric Server**. This document covers the setup, key findings,
and gotchas encountered when pointing it at InfluxDB 2 running in Kubernetes.

## Architecture

```
Proxmox (pve01, 10.10.0.2, VLAN 10)
  │  pvesh metric server (HTTPS/443)
  ▼
Traefik LoadBalancer (10.30.0.200, VLAN 30)
  │  ingress: influxdb.ruddenchaux.xyz
  ▼
InfluxDB 2 (influxdb namespace, StatefulSet)
  org: homelab  |  bucket: proxmox  |  retention: 90d
```

## Automation

### Playbook

```bash
ansible-playbook ansible/playbooks/proxmox-metrics.yml
```

**Play 1** — runs on `k8s_control_plane`:
1. Reads `admin-token` from the `influxdb-auth` k8s Secret
2. Checks whether the `proxmox` bucket exists (`kubectl exec` → `influx bucket find`)
3. Creates the `proxmox` bucket with 90d retention if missing

**Play 2** — runs on `proxmox`:
1. Sets Proxmox node DNS to the MikroTik VLAN 10 gateway (see DNS section below)
2. Creates (or updates) the `influxdb-homelab` metric server via `pvesh`

### Role defaults (`ansible/roles/proxmox-influxdb-metrics/defaults/main.yml`)

| Variable | Value |
|---|---|
| `influxdb_metrics_id` | `influxdb-homelab` |
| `influxdb_metrics_server` | `influxdb.ruddenchaux.xyz` |
| `influxdb_metrics_port` | `443` |
| `influxdb_metrics_proto` | `https` |
| `influxdb_metrics_organization` | `homelab` |
| `influxdb_metrics_bucket` | `proxmox` |

## Key Findings

### DNS: Proxmox cannot resolve internal hostnames by default

Proxmox uses a statically configured resolver, so it does not pick up DNS
settings from DHCP. Without the step below it cannot resolve
`influxdb.ruddenchaux.xyz` and `pvestatd` logs a metrics send failure every
20 seconds.

**Fix**: the role points Proxmox DNS at the MikroTik gateway on VLAN 10, which
serves split-horizon DNS for the domain (`ruddenchaux.xyz → 10.30.0.200`,
`match-subdomain=yes`) and recurses for everything else:

```bash
pvesh set /nodes/pve01/dns --dns1 10.10.0.1 --search ruddenchaux.xyz
```

The `--search` parameter is required; the call fails without it. The resolver
is configurable via `proxmox_dns_server` / `proxmox_dns_search` in the role
defaults.

> **History**: this previously pointed at AdGuardHome (`10.10.20.2`). That host
> is at Casa and unreachable from Bottega, which on 2026-09-18 left the Proxmox
> host with no working DNS at all — internal names, the Debian repos and the
> InfluxDB metrics push all failed.

### k8s node DNS has the same problem

k8s nodes also have `nameserver 10.30.0.1` (MikroTik VLAN 30 gateway) in
`/etc/resolv.conf` (static IP, not DHCP). They cannot resolve
`*.ruddenchaux.xyz` either.

**Workaround for Ansible tasks**: use `kubectl exec` into the InfluxDB pod and
run the `influx` CLI there instead of making HTTP calls to the ingress hostname
from the Ansible host. The pod's DNS goes through CoreDNS which is correctly
configured to forward `ruddenchaux.xyz` to the MikroTik gateway (10.30.0.1).

### InfluxDB is a StatefulSet, not a Deployment

The `influxdb2` Helm chart deploys a StatefulSet. `kubectl exec` must target
`statefulset/influxdb-influxdb2`, not `deployment/influxdb-influxdb2`.

### pvesh influxdbproto for InfluxDB 2

Proxmox supports three protocols: `udp`, `http`, `https`. For InfluxDB 2 over
Traefik TLS, use `https` on port `443`. The `token`, `organization`, and
`bucket` parameters are InfluxDB 2-specific (not available with UDP/v1).

### Token passed via hostvars between plays

The InfluxDB admin token is stored base64-encoded in the `influxdb-auth`
k8s Secret. Play 1 decodes it and stores it as a host fact; Play 2 reads it
via `hostvars['k8s-ctrl-01']['influxdb_admin_token']`. All tasks that touch
the token use `no_log: true`.

## Manual Verification

```bash
# Check metric server config on Proxmox
ssh root@10.10.0.2 'pvesh get /cluster/metrics/server/influxdb-homelab'

# Verify proxmox bucket exists in InfluxDB
ssh debian@10.30.0.10 \
  'kubectl exec -n influxdb statefulset/influxdb-influxdb2 -- \
   influx bucket list --org homelab --host http://localhost:8086 \
   --token $(kubectl get secret influxdb-auth -n influxdb -o jsonpath="{.data.admin-token}" | base64 -d)'

# Check Proxmox node DNS
ssh root@10.10.0.2 'pvesh get /nodes/pve01/dns'
```

Metrics appear in Proxmox UI under **Datacenter → Metric Server** with status
`active` once the first data point is sent (within ~60s of creation).
