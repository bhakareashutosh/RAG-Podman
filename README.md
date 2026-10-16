# From Laptop to Production: RAG-Powered AI Agents with Google ADK + Podman

[![Podman](https://img.shields.io/badge/Podman-5.7+-892CA0?logo=podman&logoColor=white)](https://podman.io)
[![Google Gemini](https://img.shields.io/badge/Google%20Gemini-2.5%20Flash-4285F4?logo=google&logoColor=white)](https://aistudio.google.com)
[![ChromaDB](https://img.shields.io/badge/Vector%20DB-ChromaDB-FC521F)](https://www.trychroma.com)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-YAML%20Compatible-326CE5?logo=kubernetes&logoColor=white)](https://kubernetes.io)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

An end-to-end hands-on project and workshop guide: build a Retrieval-Augmented Generation (RAG) agent using **Google's Agent Development Kit (ADK)** and **Gemini 2.5 Flash**, ground it in company documents stored in **ChromaDB**, and run it with production-grade security using **rootless, daemonless Podman**, **Kubernetes Pod manifests** (`podman kube play`), and **systemd Quadlet** services.

---

## Architecture Overview

```text
 +----------------------------------- Podman Pod: rag-pod ------------------------------------+
 |                                                                                            |
 |   User / cURL  -->  Agent Container (:8080)       localhost:8000      Chroma Container     |
 |   (Port 8080)       - ADK api_server             ---------------->    - Vector DB          |
 |                     - search_knowledge_base()                         - Volume: chroma-data|
 +------------------------------|-------------------------------------------------------------+
                                | HTTPS
                                v
                Google Gemini API (Chat + Embeddings)
```

### Key Architectural Highlights:
* **Pod Networking:** Containers inside one Podman pod share a single network namespace. The agent connects to Chroma directly on `localhost:8000`.
* **Zero Host Exposure for Database:** Only port `8080` (the ADK REST API server) is published to the host machine. The vector database remains private within the pod.
* **Rootless & Secure:** Containers run under an unprivileged user (`appuser` UID `1001`) with no root daemon on the host.
* **Secret Isolation:** The Gemini API key is managed via Podman & Kubernetes secrets (`gemini_api_key`), keeping credentials completely out of container images and Git history.

---

## ⚡ Quick Start: Interactive Dashboard

This repository includes a unified, aesthetic, and animated runner for both **Windows** (via PowerShell) and **Linux / WSL** (via Bash).

### On Windows (PowerShell)
```powershell
.\run.ps1
```

### On Linux / WSL (Bash)
```bash
./run.sh
```

Running without flags launches the **Interactive Control Console**:

```text
  ██████╗  ██████╗  ██████╗ ██╗     ███████╗   ██████╗  █████╗  ██████╗ 
 ██╔════╝ ██╔═══██╗██╔═══██╗██║     ██╔════╝   ██╔══██╗██╔══██╗██╔════╝ 
 ██║  ███╗██║   ██║██║   ██║██║     █████╗     ██████╔╝███████║██║  ███╗
 ██║   ██║██║   ██║██║   ██║██║     ██╔══╝     ██╔══██╗██╔══██║██║   ██║
 ╚██████╔╝╚██████╔╝╚██████╔╝███████╗███████╗   ██║  ██║██║  ██║╚██████╔╝
  ╚═════╝  ╚═════╝  ╚═════╝ ╚══════╝╚══════╝   ╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝ 
                 ✦ AGENT DEVELOPMENT KIT + PODMAN ✦

  CONTROL CONSOLE MENU:
  [1] 🛠️   Standard Setup & Launch  (Prereqs + Secrets + Build + Deploy + Ingest + Verify)
  [2] 💬  Interactive Chat         (Ask questions from knowledge base)
  [3] 🧪  Run Evaluation Suite     (3 standard workshop test scenarios)
  [4] 📊  Inspect Cluster Status   (Pods, containers, volumes, secrets, health)
  [5] 📜  Stream Container Logs    (Agent API & ChromaDB logs)
  [6] 📚  Re-index / Ingest Docs   (Re-chunk & embed documents into ChromaDB)
  [7] 🩺  Run System Doctor        (Verify Podman, rootless, versions, tools)
  [8] 🐍  Setup Local Dev (.venv)  (Module 1: requirements.txt for local dev)
  [9] ⚙️   Change Deployment Mode  (Current: kube)
  [10]🛑  Stop Running Workload   (Stop pod without losing vector data)
  [11]🧹  Deep Clean All           (Purge pod, volumes, secrets, and images)
  [0] 🚪  Exit
```

> **Note on API Key:** If your `GOOGLE_API_KEY` is not yet set, the script will automatically prompt you with a masked input dialog and encrypt it into your local Podman secret store.

---

## Project Structure

```text
.
├── README.md                             # Repository documentation
├── run.ps1                               # Interactive Windows PowerShell launcher
├── run.sh                                # Interactive Linux / WSL Bash runner
├── .gitignore                            # Secrets, data, and cache exclusions
├── .gitattributes                        # Enforces LF line endings for containers & shell scripts
└── adk-rag-podman/                       # Application code & manifests
    ├── Containerfile                     # Multi-layer container build (Python 3.12 slim, UID 1001)
    ├── healthcheck.py                    # Container HTTP probe script
    ├── requirements.txt                  # Python dependencies (google-adk, google-genai, chromadb-client)
    ├── agents/
    │   └── rag_agent/
    │       ├── __init__.py               # ADK app marker
    │       └── agent.py                  # Agent definition & search_knowledge_base tool
    ├── deploy/
    │   ├── rag-pod.yaml                  # Declarative Kubernetes Pod manifest
    │   ├── secret.yaml                   # Kubernetes Secret template
    │   ├── test.sh                       # Query test script
    │   └── quadlet/
    │       └── rag.kube                  # Systemd Quadlet unit file
    ├── docs/                             # Sample knowledge base documents
    │   ├── it-security.md
    │   └── leave-policy.md
    └── ingest/
        └── ingest.py                     # Document chunker, embedder, and Chroma upsert
```

---

## Workshop Step-by-Step Guide

### Module 0: Prerequisites & Setup
* **Podman 4.4+** running rootless:
  ```bash
  podman info --format '{{.Host.Security.Rootless}}' # should print true
  ```
* **Gemini API Key**: Obtain a key at [Google AI Studio](https://aistudio.google.com).
* Python 3.10+ (if testing locally outside containers).

---

### Module 1: Build the ADK Agent (Local Dev)
```bash
cd adk-rag-podman
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
export GOOGLE_API_KEY="your-api-key"
export GOOGLE_GENAI_USE_VERTEXAI=FALSE
```
* `agents/rag_agent/agent.py` defines `root_agent` and `search_knowledge_base()`.
* ADK automatically converts Python docstrings and type hints into the tool definition Gemini interprets.
* Error handling in the tool gracefully surfaces `{"status": "error"}` to the LLM instead of crashing the server.

---

### Module 2: Ingestion & Vector Database
Start a local ChromaDB container:
```bash
podman run -d --name chroma-dev -p 8000:8000 -v chroma-dev:/data docker.io/chromadb/chroma:latest
DOCS_DIR=./docs python ingest/ingest.py
```
* **Chunking Strategy:** 800-character chunks with 120-character overlap, cut cleanly at paragraph breaks.
* **Embeddings:** Generated in batches of 50 using `gemini-embedding-001`.
* **Idempotent Ingestion:** IDs are calculated using SHA-1 hashes of document filenames and chunk indexes to prevent duplicate entries.
* Run the ADK dev web interface:
  ```bash
  adk web --port 8090 agents
  ```
* Clean up dev container:
  ```bash
  podman rm -f chroma-dev
  ```

---

### Module 3: Containerize with Rootless Podman
Build the non-root image:
```bash
podman build -t localhost/rag-agent:1.0 .
podman image inspect localhost/rag-agent:1.0 --format '{{.Config.User}}' # prints 1001
```

Create the Pod and private volume:
```bash
podman pod create --name rag-pod -p 8080:8080
podman volume create chroma-data
podman run -d --pod rag-pod --name chroma -v chroma-data:/data docker.io/chromadb/chroma:latest
```

Save your API key securely into Podman's encrypted secret store:
```bash
printf '%s' "$GOOGLE_API_KEY" | podman secret create gemini_api_key -
```

Run document ingestion using an ephemeral job container:
```bash
podman run --rm --pod rag-pod \
  --secret gemini_api_key,type=env,target=GOOGLE_API_KEY \
  localhost/rag-agent:1.0 python ingest/ingest.py
```

Run the agent container with resource caps and health check:
```bash
podman run -d --pod rag-pod --name agent \
  --secret gemini_api_key,type=env,target=GOOGLE_API_KEY \
  --memory 1g --cpus 1 \
  --health-cmd 'python /app/healthcheck.py' \
  --health-interval 30s \
  localhost/rag-agent:1.0
```

---

### Module 4: Declarative Kubernetes YAML (`podman kube play`)
Podman allows running Kubernetes Pod manifests directly without needing Minikube or Kind:
```bash
# Tear down manual pod
podman pod rm -f rag-pod

# Apply secret and pod manifest
sed "s|REPLACE_WITH_YOUR_GEMINI_API_KEY|$GOOGLE_API_KEY|" deploy/secret.yaml | podman kube play -
podman kube play deploy/rag-pod.yaml

# Test querying the agent
./deploy/test.sh "How many days of annual leave do I get, and how many can I carry forward?"
```

---

### Module 5: Self-Healing System Service with Quadlet
Quadlet integrates Podman workloads directly into systemd:
```bash
mkdir -p ~/.config/containers/systemd
cp deploy/quadlet/rag.kube ~/.config/containers/systemd/
systemctl --user daemon-reload
systemctl --user start rag
systemctl --user status rag
```
* **Self-Healing:** Kill the agent container (`podman kill rag-pod-agent`) and systemd will revive it within seconds.
* **Persistent across reboots:** Run `loginctl enable-linger "$USER"` so the service persists even when logged out.

---

## 🛠️ Direct CLI Usage

The automated runner can also be driven directly via command-line flags:

| Action | PowerShell Command | Bash Command | Description |
| :--- | :--- | :--- | :--- |
| **Standard Setup** | `.\run.ps1 setup` | `./run.sh setup` | Complete automated setup: prereqs, secrets, image build, pod, ingestion & verification |
| **System Diagnostics** | `.\run.ps1 doctor` | `./run.sh doctor` | Inspects environment prerequisites, rootless mode, versions, and cluster status |
| **Launch Stack** | `.\run.ps1 up` | `./run.sh up` | Builds image, configures secrets, launches pod, and ingests docs |
| **Ask Question** | `.\run.ps1 query "<text>"` | `./run.sh query "<text>"` | Queries the running agent and prints formatted answer |
| **Interactive Chat** | `.\run.ps1 chat` | `./run.sh chat` | Opens multi-turn interactive chat loop |
| **Run Evaluation** | `.\run.ps1 test` | `./run.sh test` | Runs 3 workshop verification tests (Leave, Security, Refusal) |
| **Status** | `.\run.ps1 status` | `./run.sh status` | Displays pod, container, volume, and secret states |
| **Stream Logs** | `.\run.ps1 logs -Target agent` | `./run.sh logs agent` | Live streams container logs |
| **Re-ingest Docs** | `.\run.ps1 ingest` | `./run.sh ingest` | Re-indexes documents in `docs/` |
| **Local Dev (.venv)** | `.\run.ps1 venv` | `./run.sh venv` | Sets up local Python 3 virtual environment (.venv) and requirements |
| **Stop Workload** | `.\run.ps1 down` | `./run.sh down` | Stops pod without deleting vector data |
| **Deep Clean** | `.\run.ps1 clean` | `./run.sh clean` | Purges all containers, pods, volumes, secrets, and images |

---

## 🛡️ Production Hardening Checklist

* [x] **Non-Root Execution:** Container runs under unprivileged UID `1001`.
* [x] **Secrets Management:** Credentials injected through Kubernetes secrets / Podman secrets; never baked into images.
* [x] **Private Database Networking:** Vector database port is unexposed to the host network.
* [x] **Resource Constraints:** Memory (`1Gi`) and CPU (`1.0`) limits enforced in the pod spec.
* [x] **Health Probes:** Liveness and readiness probes monitored through `/list-apps`.
* [x] **Deterministic Ingestion:** Chunk hashes ensure idempotent updates to ChromaDB.
* [x] **Guardrails:** Explicit prompt instructions to refuse hallucination when context is missing.
