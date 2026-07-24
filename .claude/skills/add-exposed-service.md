---
name: add-exposed-service
description: Expose a new service on the cluster — Helm chart, ArgoCD app, ingress, certificate, and (if public) DNS + dst-nat + split-DNS.
---

# Add a new exposed service

Copy `specs/services/_template.md` to `specs/services/<name>.md` and fill it in
**before** writing manifests — exposure class (internal vs. public) and auth
strategy are decisions, not implementation details.

## Steps

1. **Spec first**: fill in `specs/services/<name>.md` — hostname, exposure
   class, auth (ForwardAuth vs. built-in), storage, acceptance criteria.
2. **Helm chart**: add `kubernetes/platform/<name>/` (Chart.yaml + templates),
   following the pattern of an existing service umbrella chart (e.g.
   `kubernetes/platform/authentik/` or the `media/` stack's `_helpers.tpl`
   pattern for shared labels/mounts).
3. **ArgoCD app**: add an Application manifest under
   `kubernetes/apps/templates/` so ArgoCD picks it up (sync wave per
   `README.md`'s existing convention — storage/CRDs before services that need
   them).
4. **Ingress + TLS**: Traefik `IngressRoute`/`Ingress` with a `cert-manager`
   annotation for the appropriate `ClusterIssuer` (`letsencrypt-staging` while
   testing, `letsencrypt-prod` once verified).
5. **Auth decision**: if the service has its own built-in auth (like NZBGet),
   **disable** the ForwardAuth middleware on its ingress — the `Authorization`
   header conflict causes 503s (see `TROUBLESHOOTING.md` / `CLAUDE.md`
   "Important Notes"). Otherwise attach the standard
   `authentik-authentik-auth@kubernetescrd` middleware.
6. **DNS**:
   - Internal-only: nothing to do — AdGuardHome's wildcard
     (`*.ruddenchaux.xyz → Traefik LB IP`) already covers it. This is
     split-DNS: no public record needed.
   - Public: add a Cloudflare A record pointing at Bottega's static IP (not the
     retired VPS IP — see `MIGRATION.md`), and a dst-nat rule on Bottega's
     MikroTik forwarding the relevant port to Traefik's internal LB IP. See
     `specs/network/dns-exposure.md`.
7. **Verify** against the acceptance criteria written in
   `specs/services/<name>.md` (hostname resolves as declared, certificate
   `READY=True`, auth behaves as declared).

## What changes vs. the current (VPS-relay) procedure

Today, "make a service public" means only adding a Cloudflare A record → the
VPS IP (nginx already blind-passes everything). Under the new architecture, the
A record points at **Bottega's static IP**, and Bottega's MikroTik needs an
explicit **dst-nat** rule per exposed port/service — there is no longer a
generic "any A record just works" relay in front of Traefik. This is the
trade-off for not paying a VPS: exposure is now a per-service router change,
not free.
