# Service spec: <name>

Copy this template when specifying a newly-exposed service. Fill in every
section; use `TODO(decision):` for anything not yet decided rather than
guessing.

## Summary

- **Service**: <what it is, one line>
- **Namespace / chart**: `kubernetes/platform/<name>/`
- **Hostname**: `<name>.ruddenchaux.xyz`
- **Exposure**: internal-only (split-DNS) | public (Cloudflare A record + dst-nat)

## Auth

- ForwardAuth (Authentik) enabled? yes/no — if no, state why (built-in auth
  conflicts with the `Authorization` header, per the NZBGet precedent in
  `CLAUDE.md`/`TROUBLESHOOTING.md`).
- OIDC integration, if any.

## Storage

- PVC(s) needed, size, StorageClass (default: `local-path`).

## Network path

- Internal: `Traefik → ForwardAuth (if enabled) → pod`.
- Public (if applicable): `Cloudflare A record → Bottega static IP → dst-nat
  (MikroTik) → Traefik → pod`. See `specs/network/dns-exposure.md`.

## Certificate

- cert-manager ClusterIssuer: `letsencrypt-prod` (or `-staging` while testing).

## Acceptance criteria

- [ ] Hostname resolves correctly for its exposure class (internal clients only,
      or from the raw internet, matching the "Exposure" field above).
- [ ] TLS certificate is valid (`kubectl get certificate -n <namespace>` shows
      `READY=True`).
- [ ] ForwardAuth behaves as declared (redirects to Authentik if enabled;
      reachable without SSO if built-in-auth is declared instead).
- [ ] If public: `dig <hostname>` returns Bottega's static IP, and the service
      is unreachable from outside the VPN if "Exposure" says internal-only.
