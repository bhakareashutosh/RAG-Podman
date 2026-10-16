# From Laptop to Production: ADK + RAG Agents with Podman — Lab Guide

A hands-on workshop project: build a RAG-powered agent with Google's Agent Development Kit (ADK),
ground it in documents stored in ChromaDB, and run it in production style with rootless Podman,
Kubernetes YAML and systemd (Quadlet).

```
            ┌──────────────────────── Podman pod: rag-pod ────────────────────────┐
 user ──►   │  agent container (ADK api_server :8080) ──localhost:8000──► chroma   │
 :8080      │        │  search_knowledge_base() tool                    (vectors)  │
            └────────┼────────────────────────────────────────────────── volume ───┘
                     └──► Gemini API (chat model + embeddings)
```

## Project layout

| Path | Purpose |
|---|---|
| `agents/rag_agent/agent.py` | The ADK agent and its `search_knowledge_base` RAG tool |
| `ingest/ingest.py` | Chunks `docs/`, creates Gemini embeddings, loads ChromaDB |
| `docs/` | Sample knowledge base (replace with your own `.md` / `.txt` files) |
| `Containerfile` | Image for the agent (non-root user, ADK API server) |
| `deploy/rag-pod.yaml` | Kubernetes-style Pod for `podman kube play` (and K8s/OpenShift) |
| `deploy/secret.yaml` | Template Secret holding the Gemini API key |
| `deploy/quadlet/rag.kube` | Quadlet unit to run the pod as a systemd service |
| `deploy/test.sh` | Sends a question to the running agent |

## Prerequisites (send to attendees before the workshop)

- Linux, macOS or Windows with **Podman 4.4+** (Quadlet needs Linux; on Mac/Windows use `podman machine`)
- Python 3.10+ (only needed for Module 1, local development)
- A **Gemini API key** from Google AI Studio
- `curl` and `git`

```bash
podman --version
podman info --format '{{.Host.Security.Rootless}}'   # should print: true
```

---

## Module 1 — Build the agent locally (30 min)

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
export GOOGLE_API_KEY="your-key"
export GOOGLE_GENAI_USE_VERTEXAI=FALSE
```

Walk through `agents/rag_agent/agent.py`:

- `root_agent` is the only thing ADK requires; it is an `Agent` with a model, an instruction and tools.
- `search_knowledge_base(query)` is a plain Python function. ADK turns its **docstring and type hints**
  into the tool description the model sees, so write them carefully.
- The instruction forces "retrieve first, answer only from passages, cite sources, say I don't know".

Talking point: without retrieval the model guesses; with the tool it answers from *your* data.

## Module 2 — Start the vector database and ingest data (30 min)

First run a development Chroma container with its port published, so the local agent can reach it:

```bash
podman run -d --name chroma-dev -p 8000:8000 -v chroma-dev:/data docker.io/chromadb/chroma:latest
DOCS_DIR=./docs python ingest/ingest.py
adk web --port 8090 agents     # Chroma already uses 8000
```

Open `http://localhost:8090`, pick `rag_agent`, and ask:
*"How many leave days can I carry forward?"* Open the **Events** tab to show the tool call and
retrieved chunks. Then ask something not in the docs to show the agent refusing to guess.

Explain chunking (`CHUNK_SIZE`, `CHUNK_OVERLAP`), embeddings and top-k retrieval (`TOP_K`).

Clean up the dev container: `podman rm -f chroma-dev`

## Module 3 — Containerize with Podman (45 min)

```bash
podman build -t localhost/rag-agent:1.0 .
podman image inspect localhost/rag-agent:1.0 --format '{{.Config.User}}'   # 1001, not root
```

Create a pod. Containers in a pod share one network namespace, so the agent reaches Chroma on
`localhost:8000`, and only the agent's port 8080 is published to the host:

```bash
podman pod create --name rag-pod -p 8080:8080
podman volume create chroma-data
podman run -d --pod rag-pod --name chroma \
  -v chroma-data:/data docker.io/chromadb/chroma:latest
podman pod ps && podman ps --pod
```

Store the API key as a **Podman secret** (it never appears in the image or `podman inspect`):

```bash
printf '%s' "$GOOGLE_API_KEY" | podman secret create gemini_api_key -
```

Ingest into the pod's Chroma using the same image (a one-off "job" container):

```bash
podman run --rm --pod rag-pod \
  --secret gemini_api_key,type=env,target=GOOGLE_API_KEY \
  localhost/rag-agent:1.0 python ingest/ingest.py
```

Run the agent with a health check and resource limits:

```bash
podman run -d --pod rag-pod --name agent \
  --secret gemini_api_key,type=env,target=GOOGLE_API_KEY \
  --memory 1g --cpus 1 \
  --health-cmd 'python -c "import urllib.request;urllib.request.urlopen(\"http://localhost:8080/list-apps\")"' \
  --health-interval 30s \
  localhost/rag-agent:1.0

podman ps --pod              # STATUS should become (healthy)
podman logs -f agent
./deploy/test.sh
./deploy/test.sh "What should I do if I lose my laptop?"
```

Talking points: rootless and daemonless containers, no root on the host, secrets vs environment variables,
`adk api_server` (production REST API) vs `adk web` (development UI only).

## Module 4 — Kubernetes YAML with Podman (30 min)

Show what Podman generates from the running pod:

```bash
podman kube generate rag-pod -f generated.yaml && less generated.yaml
```

Then use the clean, hand-maintained manifest in `deploy/`:

```bash
podman pod rm -f rag-pod
# put your real key in deploy/secret.yaml (do not commit it)
podman kube play deploy/secret.yaml
podman kube play deploy/rag-pod.yaml
# the PVC "chroma-data" becomes a Podman named volume; re-run ingestion if it is new:
podman run --rm --pod rag-pod --secret gemini_api_key,type=env,target=GOOGLE_API_KEY \
  localhost/rag-agent:1.0 python ingest/ingest.py
./deploy/test.sh
```

Tear down and recreate with `podman kube down deploy/rag-pod.yaml` / `podman kube play ...`.

## Module 5 — Run it as a service with Quadlet + systemd (30 min, Linux)

```bash
podman kube down deploy/rag-pod.yaml
mkdir -p ~/.config/containers/systemd
cp deploy/quadlet/rag.kube ~/.config/containers/systemd/
# make sure Yaml= in rag.kube points to where this project lives
systemctl --user daemon-reload
systemctl --user start rag
systemctl --user status rag
journalctl --user -u rag -f
loginctl enable-linger "$USER"     # keep the service running after you log out
```

Kill the agent container (`podman rm -f rag-pod-agent`) and watch systemd restart it.

## Module 6 — Production hardening checklist (30 min)

- **Pin versions**: exact `google-adk` / `chromadb-client` versions in `requirements.txt` and a fixed Chroma image tag.
- **Secrets**: Podman secrets or a vault, never baked into images or committed YAML.
- **Health and limits**: readiness/liveness probes and CPU/memory limits (already in `rag-pod.yaml`).
- **Persistence and backup**: back up the `chroma-data` volume (`podman volume export chroma-data > backup.tar`).
- **Observability**: ship `podman logs` / journald to central logging; track latency, tool errors and token usage.
- **Evaluation**: keep a set of test questions with expected answers and run them on every change
  (ADK provides an `adk eval` command for agent evaluation).
- **Guardrails**: grounded-only answers, refuse out-of-scope questions, validate tool inputs.
- **Auto-updates**: label containers with `io.containers.autoupdate=registry` and enable `podman-auto-update.timer`.
- **Next step**: push the image (`podman push`) to a registry and apply the same YAML to Kubernetes, GKE or OpenShift.

## Suggested agenda (about 4 hours)

| Time | Module |
|---|---|
| 0:00 | Intro: agents, RAG and why Podman |
| 0:15 | Module 1: Build the ADK agent |
| 0:45 | Module 2: Vector DB, chunking and ingestion |
| 1:15 | Module 3: Containerize with Podman (break after) |
| 2:15 | Module 4: Kubernetes YAML with `podman kube` |
| 2:45 | Module 5: Quadlet and systemd |
| 3:15 | Module 6: Production hardening |
| 3:45 | Q&A and wrap-up |

## Troubleshooting

| Symptom | Fix |
|---|---|
| Agent says knowledge base is unavailable | Is Chroma running in the same pod? `podman ps --pod` |
| `no_results` for every question | Ingestion was not run against this volume — re-run `ingest.py` |
| `401` / `API key not valid` | Recreate the secret: `podman secret rm gemini_api_key` then create again |
| Port 8080 already in use | Change `-p` / `hostPort` to another port |
| Quadlet unit not found | Run `systemctl --user daemon-reload`; check `/usr/libexec/podman/quadlet -dryrun -user` |
