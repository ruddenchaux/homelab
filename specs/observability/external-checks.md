# External health checks

Checks that must run from **outside** the homelab network, since anything
router-side goes silent exactly when the thing it's meant to detect (Bottega's
router/WAN) is down. This is distinct from in-cluster monitoring
(`kube-prometheus-stack`, `Loki`) documented in `CLAUDE.md`.

## Open

- `TODO(fact):` external health check against Bottega's public `443` endpoint
  (the k3s ingress, reachable per `specs/network/dns-exposure.md`) and the
  WireGuard UDP listener (`specs/network/wireguard.md`, port `61536`). Confirms
  Bottega's static IP (`145.11.24.43`, see `specs/sites/bottega.md`) is still
  reachable from the raw internet. Post-cutover, non-blocking.
