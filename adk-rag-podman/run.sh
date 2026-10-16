#!/usr/bin/env bash
# ==============================================================================
# Interactive, Aesthetic & Animated Runner: Google ADK + RAG + Podman
# ==============================================================================
set -euo pipefail

# ANSI 256-color Palette
ESC="\033"
C_RESET="${ESC}[0m"
C_BOLD="${ESC}[1m"
C_DIM="${ESC}[2m"
C_CYAN="${ESC}[38;5;51m"
C_AQUA="${ESC}[38;5;45m"
C_PURPLE="${ESC}[38;5;141m"
C_PINK="${ESC}[38;5;201m"
C_GREEN="${ESC}[38;5;48m"
C_YELLOW="${ESC}[38;5;220m"
C_RED="${ESC}[38;5;196m"
C_GRAY="${ESC}[38;5;244m"
C_WHITE="${ESC}[38;5;231m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/Containerfile" ]]; then
    PROJECT_DIR="$SCRIPT_DIR"
elif [[ -d "$SCRIPT_DIR/adk-rag-podman" ]]; then
    PROJECT_DIR="$SCRIPT_DIR/adk-rag-podman"
else
    PROJECT_DIR="$SCRIPT_DIR"
fi

IMAGE_TAG="localhost/rag-agent:1.0"
POD_NAME="rag-pod"
CHROMA_VOLUME="chroma-data"
CHROMA_IMAGE="docker.io/chromadb/chroma:latest"
PORT="8080"
DEPLOY_MODE="kube"
FORCE_BUILD=false
API_KEY="${GOOGLE_API_KEY:-}"
ACTION="menu"
CUSTOM_QUERY=""
TARGET_CONTAINER="agent"

# ------------------------------------------------------------------------------
# Animations & Helpers
# ------------------------------------------------------------------------------

typewriter() {
    local text="$1"
    local delay="${2:-0.005}"
    local color="${3:-$C_WHITE}"
    echo -ne "$color"
    for (( i=0; i<${#text}; i++ )); do
        echo -n "${text:$i:1}"
        sleep "$delay"
    done
    echo -e "$C_RESET"
}

show_spinner() {
    local message="$1"
    local duration="${2:-2}"
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local end=$((SECONDS + duration))
    local i=0
    while (( SECONDS < end )); do
        local frame="${frames[$((i % ${#frames[@]}))]}"
        echo -ne "\r  ${C_CYAN}${frame}${C_RESET} ${C_BOLD}${message}${C_RESET}  "
        sleep 0.08
        ((i++))
    done
    echo -e "\r  ${C_GREEN}✔${C_RESET} ${C_BOLD}${message}${C_RESET}   "
}

is_api_server_up() {
    curl -s -f "http://localhost:${PORT}/list-apps" &>/dev/null
}

wait_for_api_ready() {
    local timeout="${1:-45}"
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local end=$((SECONDS + timeout))
    local i=0
    echo ""
    while (( SECONDS < end )); do
        if is_api_server_up; then
            echo -e "\r  ${C_GREEN}✔${C_RESET} ${C_BOLD}ADK REST API Server is UP & HEALTHY at http://localhost:${PORT}!${C_RESET}       \n"
            return 0
        fi
        local frame="${frames[$((i % ${#frames[@]}))]}"
        local elapsed=$((timeout - (end - SECONDS)))
        echo -ne "\r  ${C_PURPLE}${frame}${C_RESET} ${C_BOLD}Waiting for ADK API server readiness...${C_RESET} ${C_GRAY}(${elapsed}s / ${timeout}s)${C_RESET}  "
        sleep 0.25
        ((i++))
    done
    echo -e "\r  ${C_YELLOW}⚠${C_RESET} ${C_YELLOW}Healthcheck wait finished (server may still be starting).${C_RESET}              \n"
}

ensure_api_key() {
    if [[ -n "$API_KEY" ]]; then
        export GOOGLE_API_KEY="$API_KEY"
        return 0
    fi

    if [[ -n "${GOOGLE_API_KEY:-}" ]]; then
        API_KEY="$GOOGLE_API_KEY"
        return 0
    fi

    # Check if already in Podman secret
    if podman secret inspect gemini_api_key &>/dev/null; then
        return 0
    fi

    echo ""
    echo -e "${C_CYAN}  ╭────────────────────────────────────────────────────────────────────────╮${C_RESET}"
    echo -e "${C_CYAN}  │  ${C_YELLOW}🔐 GEMINI API KEY CONFIGURATION${C_CYAN}                                       │${C_RESET}"
    echo -e "${C_CYAN}  ├────────────────────────────────────────────────────────────────────────┤${C_RESET}"
    echo -e "${C_CYAN}  │${C_RESET}  The ADK Agent & ChromaDB vector pipeline use Google Gemini models:    ${C_CYAN}│${C_RESET}"
    echo -e "${C_CYAN}  │${C_RESET}    • Chat Model:       ${C_GREEN}gemini-2.5-flash${C_RESET}                                   ${C_CYAN}│${C_RESET}"
    echo -e "${C_CYAN}  │${C_RESET}    • Embeddings Model: ${C_GREEN}gemini-embedding-001${C_RESET}                               ${C_CYAN}│${C_RESET}"
    echo -e "${C_CYAN}  │${C_RESET}                                                                        ${C_CYAN}│${C_RESET}"
    echo -e "${C_CYAN}  │${C_RESET}  Get a free key at: ${C_AQUA}https://aistudio.google.com${C_RESET}                            ${C_CYAN}│${C_RESET}"
    echo -e "${C_CYAN}  ╰────────────────────────────────────────────────────────────────────────╯${C_RESET}"
    echo ""

    while [[ -z "$API_KEY" ]]; do
        echo -ne "  ${C_YELLOW}▶ Paste your Gemini API Key:${C_RESET} "
        read -rs API_KEY
        echo ""
        if [[ -z "$API_KEY" ]]; then
            echo -e "  ${C_RED}✖ API key cannot be empty! Please paste your key.${C_RESET}\n"
        fi
    done

    export GOOGLE_API_KEY="$API_KEY"
    show_spinner "Saving key to encrypted Podman secret 'gemini_api_key'..." 1
    printf '%s' "$API_KEY" | podman secret rm gemini_api_key >/dev/null 2>&1 || true
    printf '%s' "$API_KEY" | podman secret create gemini_api_key -

    # Register in secret.yaml template
    if [[ -f "$PROJECT_DIR/deploy/secret.yaml" ]]; then
        local tmp_sec
        tmp_sec=$(mktemp)
        sed "s|REPLACE_WITH_YOUR_GEMINI_API_KEY|$API_KEY|" "$PROJECT_DIR/deploy/secret.yaml" > "$tmp_sec"
        podman kube play "$tmp_sec" >/dev/null 2>&1 || true
        rm -f "$tmp_sec"
    fi

    echo -e "  ${C_GREEN}✔ Key successfully configured and registered!${C_RESET}\n"
}

# ------------------------------------------------------------------------------
# UI: Header & Dashboard
# ------------------------------------------------------------------------------

show_header() {
    clear 2>/dev/null || true
    local status_pill
    if is_api_server_up; then
        status_pill="${C_GREEN}● ACTIVE (:8080)${C_RESET}"
    else
        status_pill="${C_RED}○ STOPPED${C_RESET}"
    fi

    local key_pill
    if [[ -n "${GOOGLE_API_KEY:-}" ]] || podman secret inspect gemini_api_key &>/dev/null; then
        key_pill="${C_GREEN}● CONFIGURED${C_RESET}"
    else
        key_pill="${C_YELLOW}○ NOT SET${C_RESET}"
    fi

    echo -e "${C_CYAN}"
    echo -e "  ██████╗  ██████╗  ██████╗ ██╗     ███████╗   ██████╗  █████╗  ██████╗ "
    echo -e " ██╔════╝ ██╔═══██╗██╔═══██╗██║     ██╔════╝   ██╔══██╗██╔══██╗██╔════╝ "
    echo -e " ██║  ███╗██║   ██║██║   ██║██║     █████╗     ██████╔╝███████║██║  ███╗"
    echo -e " ██║   ██║██║   ██║██║   ██║██║     ██╔══╝     ██╔══██╗██╔══██║██║   ██║"
    echo -e " ╚██████╔╝╚██████╔╝╚██████╔╝███████╗███████╗   ██║  ██║██║  ██║╚██████╔╝"
    echo -e "  ╚═════╝  ╚═════╝  ╚═════╝ ╚══════╝╚══════╝   ╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝ "
    echo -e "                 ${C_PURPLE}✦ AGENT DEVELOPMENT KIT + PODMAN ✦${C_RESET}\n"
    echo -e "${C_CYAN}  ╭────────────────────────────────────────────────────────────────────────╮${C_RESET}"
    echo -e "${C_CYAN}  │${C_RESET} ${C_BOLD}Container Engine :${C_RESET} ${C_AQUA}Rootless Podman $(podman --version | awk '{print $3}')${C_RESET}                         ${C_CYAN}│${C_RESET}"
    echo -e "${C_CYAN}  │${C_RESET} ${C_BOLD}Agent Stack      :${C_RESET} ${C_PURPLE}Google ADK + Gemini 2.5 Flash + ChromaDB${C_RESET}           ${C_CYAN}│${C_RESET}"
    echo -e "${C_CYAN}  │${C_RESET} ${C_BOLD}Deployment Mode  :${C_RESET} ${C_YELLOW}${DEPLOY_MODE^^}${C_RESET}                                              ${C_CYAN}│${C_RESET}"
    echo -e "${C_CYAN}  │${C_RESET} ${C_BOLD}Cluster Status   :${C_RESET} $status_pill                                      ${C_CYAN}│${C_RESET}"
    echo -e "${C_CYAN}  │${C_RESET} ${C_BOLD}Gemini API Key   :${C_RESET} $key_pill                                  ${C_CYAN}│${C_RESET}"
    echo -e "${C_CYAN}  ╰────────────────────────────────────────────────────────────────────────╯${C_RESET}"
}

# ------------------------------------------------------------------------------
# Action Implementations
# ------------------------------------------------------------------------------

action_build() {
    show_header
    echo -e "\n${C_CYAN}==> Verifying / Building Agent Image (${IMAGE_TAG})...${C_RESET}"
    if podman image inspect "$IMAGE_TAG" &>/dev/null && [[ "$FORCE_BUILD" == "false" ]]; then
        show_spinner "Container image verified in local storage" 1
    else
        echo -e "  Building container image from $PROJECT_DIR/Containerfile..."
        podman build -t "$IMAGE_TAG" "$PROJECT_DIR"
        echo -e "  ${C_GREEN}✔ Image built successfully!${C_RESET}"
    fi
}

action_up() {
    show_header
    echo -e "\n${C_BOLD}${C_AQUA}═══ STARTING FULL AUTOMATED DEPLOYMENT ═══${C_RESET}\n"
    ensure_api_key

    # Step 1: Image
    echo -e "${C_CYAN}==> [1/5] Checking container image...${C_RESET}"
    if ! podman image inspect "$IMAGE_TAG" &>/dev/null || [[ "$FORCE_BUILD" == "true" ]]; then
        podman build -t "$IMAGE_TAG" "$PROJECT_DIR"
    else
        show_spinner "Image $IMAGE_TAG ready" 1
    fi

    # Step 2: Secrets
    echo -e "\n${C_CYAN}==> [2/5] Configuring secrets...${C_RESET}"
    if ! podman secret inspect gemini_api_key &>/dev/null; then
        printf '%s' "$API_KEY" | podman secret create gemini_api_key -
    fi
    show_spinner "Secrets verified" 1

    # Step 3: Pod Deployment
    echo -e "\n${C_CYAN}==> [3/5] Starting Pod via $DEPLOY_MODE mode...${C_RESET}"
    podman pod rm -f "$POD_NAME" >/dev/null 2>&1 || true

    if [[ "$DEPLOY_MODE" == "kube" ]]; then
        local pod_yaml="$PROJECT_DIR/deploy/rag-pod.yaml"
        if [[ "$PORT" != "8080" ]]; then
            local tmp_pod
            tmp_pod=$(mktemp)
            sed "s|hostPort: 8080|hostPort: $PORT|" "$pod_yaml" > "$tmp_pod"
            podman kube play "$tmp_pod"
            rm -f "$tmp_pod"
        else
            podman kube play "$pod_yaml"
        fi
    elif [[ "$DEPLOY_MODE" == "pod" ]]; then
        podman volume inspect "$CHROMA_VOLUME" &>/dev/null || podman volume create "$CHROMA_VOLUME"
        podman pod create --name "$POD_NAME" -p "${PORT}:8080"
        podman run -d --pod "$POD_NAME" --name chroma -v "${CHROMA_VOLUME}:/data" "$CHROMA_IMAGE"
        podman run -d --pod "$POD_NAME" --name agent \
            --secret gemini_api_key,type=env,target=GOOGLE_API_KEY \
            --memory 1g --cpus 1 \
            --health-cmd 'python -c "import urllib.request;urllib.request.urlopen(\"http://localhost:8080/list-apps\")"' \
            --health-interval 30s \
            "$IMAGE_TAG"
    elif [[ "$DEPLOY_MODE" == "quadlet" ]]; then
        local qdir="$HOME/.config/containers/systemd"
        mkdir -p "$qdir"
        sed "s|Yaml=%h/adk-rag-podman/deploy/rag-pod.yaml|Yaml=$PROJECT_DIR/deploy/rag-pod.yaml|" \
            "$PROJECT_DIR/deploy/quadlet/rag.kube" > "$qdir/rag.kube"
        systemctl --user daemon-reload
        systemctl --user start rag
    fi
    show_spinner "Pod containers initialized" 2

    # Step 4: Ingestion
    echo -e "\n${C_CYAN}==> [4/5] Ingesting documents into ChromaDB...${C_RESET}"
    podman run --rm --pod "$POD_NAME" \
        --secret gemini_api_key,type=env,target=GOOGLE_API_KEY \
        "$IMAGE_TAG" python ingest/ingest.py

    # Step 5: Health Check
    echo -e "\n${C_CYAN}==> [5/5] Verifying REST API Server Readiness...${C_RESET}"
    wait_for_api_ready 45

    echo -e "${C_CYAN}==> [Verification] Asking sample question...${C_RESET}"
    action_query "How many days of annual leave do I get, and how many can I carry forward?"

    echo -e "\n${C_GREEN}${C_BOLD}✨ WORKSPACE IS READY & RUNNING!${C_RESET}\n"
}

action_query() {
    local q="${1:-}"
    if [[ -z "$q" ]]; then
        echo -ne "  ${C_YELLOW}▶ Enter question for the agent:${C_RESET} "
        read -r q
        if [[ -z "$q" ]]; then return; fi
    fi

    local url="http://localhost:${PORT}"
    local sid="s-$(date +%s)"

    echo ""
    echo -e "${C_PURPLE}  ╭────────────────────────────────────────────────────────────────────────╮${C_RESET}"
    echo -e "${C_PURPLE}  │  ${C_BOLD}💬 QUESTION:${C_RESET} $q"
    echo -e "${C_PURPLE}  ╰────────────────────────────────────────────────────────────────────────╯${C_RESET}"

    # Create session
    if ! curl -s -f -X POST "$url/apps/rag_agent/users/u1/sessions/$sid" \
        -H "Content-Type: application/json" -d '{}' &>/dev/null; then
        echo -e "  ${C_RED}✖ Could not connect to ADK server on port $PORT. Is the pod running?${C_RESET}"
        return
    fi

    echo -ne "  ${C_CYAN}⠋${C_RESET} ${C_BOLD}Consulting ChromaDB & reasoning with Gemini 2.5 Flash...${C_RESET}"

    local payload
    payload=$(cat <<JSON
{"app_name":"rag_agent","user_id":"u1","session_id":"$sid","new_message":{"role":"user","parts":[{"text":"$q"}]}}
JSON
)

    local resp
    resp=$(curl -s -X POST "$url/run" -H "Content-Type: application/json" -d "$payload" || echo "[]")
    echo -ne "\r                                                                       \r"

    echo -e "${C_GREEN}  ╭──────────────────────────── AGENT RESPONSE ────────────────────────────╮${C_RESET}"
    if command -v python3 &>/dev/null; then
        echo "$resp" | python3 -c '
import json, sys
try:
    events = json.load(sys.stdin)
    found = False
    for ev in events:
        for p in (ev.get("content") or {}).get("parts", []):
            if p.get("text"):
                print("  " + p["text"])
                found = True
    if not found:
        print("  [No text answer returned]")
except Exception as e:
    print(f"  Error parsing response: {e}")
'
    else
        echo "  $resp"
    fi
    echo -e "${C_GREEN}  ╰────────────────────────────────────────────────────────────────────────╯${C_RESET}\n"
}

action_chat() {
    show_header
    echo -e "\n${C_BOLD}${C_AQUA}═══ INTERACTIVE AGENT CHAT SESSION ═══${C_RESET}"
    echo -e "${C_GRAY}Type your question, or type 'exit' / 'back' to return to menu.${C_RESET}\n"

    while true; do
        echo -ne "${C_YELLOW}Agent Chat ▶ ${C_RESET}"
        read -r input_q
        if [[ "$input_q" == "exit" || "$input_q" == "back" || "$input_q" == "quit" || -z "$input_q" ]]; then
            break
        fi
        action_query "$input_q"
    done
}

action_test() {
    show_header
    echo -e "\n${C_BOLD}${C_AQUA}═══ RUNNING COMPLETE WORKSHOP EVALUATION SUITE ═══${C_RESET}\n"

    echo -e "${C_CYAN}── Scenario 1: Leave Policy Retrieval ──${C_RESET}"
    action_query "How many days of annual leave do I get, and how many can I carry forward?"

    echo -e "${C_CYAN}── Scenario 2: IT Security Policy Retrieval ──${C_RESET}"
    action_query "What should I do if I lose my laptop?"

    echo -e "${C_CYAN}── Scenario 3: Guardrail & Refusal Test (Out of Scope) ──${C_RESET}"
    action_query "What is the company dress code for casual Fridays?"

    echo -e "${C_GREEN}${C_BOLD}✔ Evaluation Suite Completed!${C_RESET}\n"
}

action_ingest() {
    show_header
    echo -e "\n${C_BOLD}${C_AQUA}═══ DOCUMENT INGESTION PIPELINE ═══${C_RESET}\n"
    ensure_api_key
    podman run --rm --pod "$POD_NAME" \
        --secret gemini_api_key,type=env,target=GOOGLE_API_KEY \
        "$IMAGE_TAG" python ingest/ingest.py
    echo -e "\n${C_GREEN}✔ Ingestion completed! Vectors updated in ChromaDB.${C_RESET}\n"
}

action_status() {
    show_header
    echo -e "\n${C_BOLD}${C_AQUA}═══ POD & CONTAINER STATUS ═══${C_RESET}\n"
    echo -e "${C_BOLD}Pods:${C_RESET}"
    podman pod ps || true
    echo -e "\n${C_BOLD}Containers:${C_RESET}"
    podman ps -a --pod || true
    echo -e "\n${C_BOLD}Volumes:${C_RESET}"
    podman volume ls || true
    echo -e "\n${C_BOLD}Secrets:${C_RESET}"
    podman secret ls || true
    echo ""
}

action_logs() {
    local target="${TARGET_CONTAINER:-agent}"
    show_header
    echo -e "\n${C_BOLD}${C_AQUA}═══ STREAMING LOGS ($target) ═══${C_RESET}"
    echo -e "${C_GRAY}(Press Ctrl+C to stop streaming)${C_RESET}\n"
    local cname
    cname=$(podman ps -a --format '{{.Names}}' | grep "$target" | head -n 1 || true)
    if [[ -n "$cname" ]]; then
        podman logs -f "$cname"
    else
        echo -e "  ${C_RED}✖ No running container matching '$target' found.${C_RESET}\n"
    fi
}

action_stop() {
    show_header
    echo -e "\n${C_BOLD}${C_YELLOW}═══ STOPPING WORKLOAD ═══${C_RESET}\n"
    show_spinner "Stopping pod and services..." 2
    if systemctl --user is-active rag &>/dev/null; then
        systemctl --user stop rag || true
    fi
    if [[ -f "$PROJECT_DIR/deploy/rag-pod.yaml" ]]; then
        podman kube down "$PROJECT_DIR/deploy/rag-pod.yaml" 2>/dev/null || true
    fi
    podman pod rm -f "$POD_NAME" 2>/dev/null || true
    echo -e "${C_GREEN}✔ Workload stopped.${C_RESET}\n"
}

action_clean() {
    show_header
    echo -e "\n${C_BOLD}${C_RED}═══ DEEP CLEANUP ═══${C_RESET}\n"
    echo -ne "  ${C_RED}⚠ Are you sure you want to remove pods, volumes, secrets, and images? (y/N): ${C_RESET}"
    read -r confirm
    if [[ "$confirm" =~ ^[yY]$ ]]; then
        show_spinner "Purging all workshop resources..." 2
        action_stop
        podman volume rm -f "$CHROMA_VOLUME" 2>/dev/null || true
        podman secret rm gemini_api_key gemini-secret 2>/dev/null || true
        podman rmi -f "$IMAGE_TAG" 2>/dev/null || true
        echo -e "${C_GREEN}✔ All workshop resources cleaned.${C_RESET}\n"
    else
        echo -e "  ${C_GRAY}Cleanup cancelled.${C_RESET}\n"
    fi
}

# ------------------------------------------------------------------------------
# Interactive Menu Loop
# ------------------------------------------------------------------------------

run_menu() {
    while true; do
        show_header
        echo -e "${C_BOLD}  CONTROL CONSOLE MENU:${C_RESET}"
        echo -e "  ${C_AQUA}[1]${C_RESET} ${C_BOLD}🚀  Launch Complete Stack${C_RESET}   ${C_GRAY}(Build + Secrets + Deploy + Ingest + Verify)${C_RESET}"
        echo -e "  ${C_AQUA}[2]${C_RESET} ${C_BOLD}💬  Interactive Chat${C_RESET}          ${C_GRAY}(Ask questions from knowledge base)${C_RESET}"
        echo -e "  ${C_AQUA}[3]${C_RESET} ${C_BOLD}🧪  Run Evaluation Suite${C_RESET}      ${C_GRAY}(3 standard workshop test scenarios)${C_RESET}"
        echo -e "  ${C_AQUA}[4]${C_RESET} ${C_BOLD}📊  Inspect Cluster Status${C_RESET}    ${C_GRAY}(Pods, containers, volumes, secrets)${C_RESET}"
        echo -e "  ${C_AQUA}[5]${C_RESET} ${C_BOLD}📜  Stream Container Logs${C_RESET}     ${C_GRAY}(Agent API & ChromaDB logs)${C_RESET}"
        echo -e "  ${C_AQUA}[6]${C_RESET} ${C_BOLD}📚  Re-index / Ingest Docs${C_RESET}    ${C_GRAY}(Re-chunk & embed documents into ChromaDB)${C_RESET}"
        echo -e "  ${C_AQUA}[7]${C_RESET} ${C_BOLD}⚙️   Change Deployment Mode${C_RESET}   ${C_GRAY}(Current: $DEPLOY_MODE)${C_RESET}"
        echo -e "  ${C_AQUA}[8]${C_RESET} ${C_BOLD}🛑  Stop Running Workload${C_RESET}     ${C_GRAY}(Stop pod without losing vector data)${C_RESET}"
        echo -e "  ${C_AQUA}[9]${C_RESET} ${C_BOLD}🧹  Deep Clean All${C_RESET}            ${C_GRAY}(Purge pod, volumes, secrets, and images)${C_RESET}"
        echo -e "  ${C_AQUA}[0]${C_RESET} ${C_BOLD}🚪  Exit${C_RESET}\n"
        echo -ne "  ${C_YELLOW}Select an option [0-9]:${C_RESET} "
        
        read -r choice
        case "$choice" in
            1) action_up; echo -ne "  ${C_GRAY}Press Enter to return to menu...${C_RESET}"; read -r ;;
            2) action_chat ;;
            3) action_test; echo -ne "  ${C_GRAY}Press Enter to return to menu...${C_RESET}"; read -r ;;
            4) action_status; echo -ne "  ${C_GRAY}Press Enter to return to menu...${C_RESET}"; read -r ;;
            5) action_logs ;;
            6) action_ingest; echo -ne "  ${C_GRAY}Press Enter to return to menu...${C_RESET}"; read -r ;;
            7)
                echo -e "\n  Select Mode: [1] kube (default)  [2] pod  [3] quadlet"
                echo -ne "  Choice: "
                read -r mc
                if [[ "$mc" == "1" ]]; then DEPLOY_MODE="kube"; fi
                if [[ "$mc" == "2" ]]; then DEPLOY_MODE="pod"; fi
                if [[ "$mc" == "3" ]]; then DEPLOY_MODE="quadlet"; fi
                ;;
            8) action_stop; sleep 1 ;;
            9) action_clean; echo -ne "  ${C_GRAY}Press Enter to return to menu...${C_RESET}"; read -r ;;
            0) echo -e "\n  ${C_GREEN}Goodbye! 👋${C_RESET}\n"; exit 0 ;;
            *) sleep 0.5 ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# Argument Parsing for Direct CLI Invocation
# ------------------------------------------------------------------------------

if [[ $# -eq 0 ]]; then
    run_menu
    exit 0
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        up|down|stop|test|status|clean|build|ingest|chat|menu)
            ACTION="$1"
            shift
            ;;
        query)
            ACTION="query"
            shift
            if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
                CUSTOM_QUERY="$1"
                shift
            fi
            ;;
        logs)
            ACTION="logs"
            shift
            if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
                TARGET_CONTAINER="$1"
                shift
            fi
            ;;
        --mode)
            DEPLOY_MODE="$2"
            shift 2
            ;;
        --key)
            API_KEY="$2"
            shift 2
            ;;
        --port)
            PORT="$2"
            shift 2
            ;;
        --force-build)
            FORCE_BUILD=true
            shift
            ;;
        *)
            echo "Unknown argument: $1"
            exit 1
            ;;
    esac
done

case "$ACTION" in
    menu)   run_menu ;;
    up)     action_up ;;
    down|stop) action_stop ;;
    test)   action_test ;;
    query)  action_query "$CUSTOM_QUERY" ;;
    chat)   action_chat ;;
    ingest) action_ingest ;;
    status) action_status ;;
    logs)   action_logs ;;
    clean)  action_clean ;;
    build)  action_build ;;
esac
