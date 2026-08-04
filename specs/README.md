# specs/

This directory is the **intent layer**: the single source of truth for network
and site design decisions, written before any Ansible, Terraform, or Kubernetes
change that implements them.

## Why a separate layer

`ansible/`, `terraform/`, `kubernetes/` describe **how** the lab is configured.
They don't say **why** a subnet was chosen, why Bottega is the hub, or what
"done" means for a WireGuard peer. Without that, every change has to be
re-derived from source, which is slow and error-prone once there are two sites
and two routers instead of one.

Specs fix that: a decision is written down once, in one place, before it's
implemented.

## How specs relate to the implementation layers

```
specs/                  ← intent: what should be true, and why
  network/, sites/, services/
        │
        │ implemented by
        ▼
ansible/, terraform/, packer/, kubernetes/
        │
        │ produces
        ▼
running infrastructure
```

- A spec describes a target state and its **acceptance criteria** — written so
  they can be checked by an executable connectivity test, not as prose.
- Ansible/Terraform/Kubernetes changes should reference the spec they implement
  (e.g. in a commit message or PR description).
- If reality and a spec disagree, that's a bug in one of the two — fix the spec
  first if the decision changed, fix the implementation if it didn't.

## What's here

- `network/topology.md` — sites, roles, hub-and-spoke rationale, addressing plan.
- `network/wireguard.md` — peer matrix, AllowedIPs table, acceptance criteria.
- `network/firewall.md` — input/forward intent per site.
- `network/dns-exposure.md` — public records, dst-nat, split-DNS.
- `sites/bottega.md`, `sites/casa.md` — per-site role and constraints.
- `sites/bottega-phase-2-lockdown.md` — phase-specific WAN-up/no-WAN-answer
  guardrails for Bottega.
- `sites/bottega-phase-3-vlans.md` — Bottega VLAN provisioning, tagged R740xd
  uplink, safe application, and power-on checkpoint.
- `sites/bottega-phase-4-public-https.md` — direct public TCP `443` forwarding
  to Traefik and the multi-host DNS cutover.
- `sites/bottega-phase-5-wireguard.md` — the WireGuard hub on UDP `61536`, the
  road-warrior peer, and the declared input-exception model.
- `services/_template.md` — template for specifying a newly-exposed service.
- `observability/external-checks.md` — health checks that must run from
  outside the network.

## Open decisions

Any value that isn't decided yet is marked `TODO(decision):` inline, rather than
invented. Do not fill in a `TODO(decision):` with a plausible-looking value —
raise it with the repo owner instead.
