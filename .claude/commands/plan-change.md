---
description: Produce a plan against the relevant spec before touching any file.
---

# /plan-change

Use before any network, Ansible, Terraform, or Kubernetes change that has a
corresponding spec.

## Steps

1. Identify which spec(s) under `specs/` govern this change (`topology.md`,
   `wireguard.md`, `firewall.md`, `dns-exposure.md`, a site file, or a service
   spec). If none exists yet for this change, say so — don't proceed as if one
   does.
2. Check the spec for open `TODO(decision):` markers that block this change.
   If the change depends on an undecided value, stop and surface it rather
   than inventing a value.
3. Produce a plan that:
   - States which files it will touch (grouped by `ansible/` / `terraform/` /
     `kubernetes/` / `specs/`).
   - States which `AGENTS.md` rules apply (secrets separation, subnet overlap,
     WireGuard both-ends, MikroTik safe-mode, router-mgmt-never-on-WAN) and how
     the plan satisfies each one.
   - States the acceptance criteria from the spec this change is meant to
     satisfy, verbatim or specifically referenced.
4. Do not apply the change in this step — this command only produces the plan.
