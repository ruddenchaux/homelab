# Anysub (Whishper v4)

Self-hosted audio transcription + diarization at https://transcribe.ruddenchaux.xyz.
Upstream: https://github.com/pluja/whishper/tree/v4 (status: WIP, last commit
2025-06-30).

## Architecture

Single-namespace Helm chart (`anysub`):

| Workload | Pods | Purpose |
|---|---|---|
| `anysub` Deployment | 3 containers in 1 Pod: `web`, `worker`, `redis` | Web UI on `:1337`; queue worker; in-pod Asynq Redis |
| `mariadb` Deployment | 1 | Anysub metadata store |
| `libretranslate` Deployment | 1 | Optional translation backend |

The `web` and `worker` containers share the same image (a Go binary compiled
into `pluja/whisperx-api:cpu`). They share the Pod because
`src/server/server.go` hardcodes the Asynq client to `127.0.0.1:6379` — the
in-pod Redis sidecar is the only way to make web + queue see the same broker
without patching upstream.

All workloads pin to `k8s-worker-04` via `nodeSelector` because local-path
PVCs are node-local.

## How to access it

`https://transcribe.ruddenchaux.xyz` — register the first user via
`/register`, then `/login`. Anysub manages its own auth and per-user
workspaces; **there is no Authentik ForwardAuth** in front of it. Service is
not exposed beyond the LAN.

## Hugging Face token

Diarization needs a token with `read` scope from
https://huggingface.co/settings/tokens. Accept terms for both
[`pyannote/speaker-diarization-3.1`](https://huggingface.co/pyannote/speaker-diarization-3.1)
and [`pyannote/segmentation-3.0`](https://huggingface.co/pyannote/segmentation-3.0).

The token lives in `ansible/secrets.sops.yml` under the key
`anysub_hf_token`. Add or rotate it with:

```bash
sops ansible/secrets.sops.yml
# add:  anysub_hf_token: hf_xxx
ansible-playbook ansible/playbooks/anysub-secrets.yml
```

The Ansible role re-runs `kubectl patch` on the `anysub-secrets` Secret with
the current token value, so rotation is just an SOPS edit + replay.

## Image build

Upstream does not publish a worker image — `worker.cpu.Dockerfile` builds
locally from the `src/` directory of the whishper v4 branch. One-time build &
push:

```bash
git clone --branch v4 https://github.com/pluja/whishper.git /tmp/whishper
cd /tmp/whishper
SHA=$(git rev-parse --short HEAD)
docker build -f src/worker.cpu.Dockerfile -t ghcr.io/ruddenchaux/anysub-worker:cpu-${SHA} src/
docker push ghcr.io/ruddenchaux/anysub-worker:cpu-${SHA}
```

Then update `images.worker` in `values.yaml` to the new tag and let ArgoCD
sync. The `cpu-v4` placeholder in this chart is a tag you must create on
first deploy.

## How to scale

You don't. v4 is single-replica by design (Asynq queue + local-path PVCs).
Throughput grows by raising `whisper.threads` and the worker CPU limit, not
replica count. The chart caps at 18 threads / 18 cores / 12 Gi RAM — one NUMA
socket on the underlying Xeon Gold 6140 host. Going wider means cross-socket
memory traffic that hurts faster-whisper performance.

## Known limitations

- **No NUMA pinning.** The cluster doesn't run with `--topology-manager-policy`
  or CPU manager static policy. Threads may bounce between sockets.
- **Concurrency is one job at a time.** Asynq picks up jobs serially in v4.
- **Web UI registration is open** to anyone who can reach `:1337` on the LAN.
  Lock down via firewall if friends-of-friends sharing isn't desired.
- **No automated image rebuilds.** When the upstream v4 branch advances you
  must rebuild and push the worker image manually.
