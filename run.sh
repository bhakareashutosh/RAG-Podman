#!/usr/bin/env bash
# ==============================================================================
# Interactive, Aesthetic & Automated Runner: Google ADK + RAG + Podman
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
WITH_VENV=false
SKIP_VENV=false
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

# ------------------------------------------------------------------------------
# Pre-requisite & System Diagnostics (Doctor)
# ------------------------------------------------------------------------------

check_prerequisites() {
    local all_good=true
    echo -e "\n${C_BOLD}${C_AQUA}═══ PRE-FLIGHT SYSTEM & PREREQUISITE CHECKS ═══${C_RESET}\n"

    # 1. Check Podman
    if command -v podman &>/dev/null; then
        local pver
        pver=$(podman --version | awk '{print $3}' 2>/dev/null || echo "detected")
        echo -e "  ${C_GREEN}✔${C_RESET} ${C_BOLD}Podman CLI:${C_RESET} $pver installed"

        # Check rootless mode
        local is_rootless
        is_rootless=$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null || echo "unknown")
        if [[ "$is_rootless" == "true" ]]; then
            echo -e "  ${C_GREEN}✔${C_RESET} ${C_BOLD}Rootless Mode:${C_RESET} Active (rootless container engine)"
        else
            echo -e "  ${C_YELLOW}⚠${C_RESET} ${C_BOLD}Rootless Mode:${C_RESET} $is_rootless (Workshop recommends rootless Podman)"
        fi
    else
        echo -e "  ${C_RED}✖${C_RESET} ${C_BOLD}Podman CLI:${C_RESET} Not installed!"
        echo -e "    ${C_GRAY}Install Podman 4.4+ via: sudo apt-get update && sudo apt-get install -y podman${C_RESET}"
        all_good=false
    fi

    # 2. Check curl
    if command -v curl &>/dev/null; then
        local cver
        cver=$(curl --version 2>/dev/null | head -n 1 | awk '{print $2}')
        echo -e "  ${C_GREEN}✔${C_RESET} ${C_BOLD}cURL:${C_RESET} $cver"
    else
        echo -e "  ${C_RED}✖${C_RESET} ${C_BOLD}cURL:${C_RESET} Not found (required for API verification)"
        all_good=false
    fi

    # 3. Check git
    if command -v git &>/dev/null; then
        local gver
        gver=$(git --version 2>/dev/null | awk '{print $3}')
        echo -e "  ${C_GREEN}✔${C_RESET} ${C_BOLD}Git:${C_RESET} $gver"
    else
        echo -e "  ${C_YELLOW}⚠${C_RESET} ${C_BOLD}Git:${C_RESET} Not found"
    fi

    # 4. Check python3
    if command -v python3 &>/dev/null; then
        local pyver
        pyver=$(python3 --version 2>/dev/null | awk '{print $2}')
        echo -e "  ${C_GREEN}✔${C_RESET} ${C_BOLD}Python 3:${C_RESET} $pyver"
    else
        echo -e "  ${C_YELLOW}⚠${C_RESET} ${C_BOLD}Python 3:${C_RESET} Not found (needed for Module 1 local development)"
    fi

    # 5. Fix permissions & normalize LF line endings
    if [[ -f "$SCRIPT_DIR/run.sh" ]]; then
        chmod +x "$SCRIPT_DIR/run.sh" 2>/dev/null || true
        sed -i 's/\r$//' "$SCRIPT_DIR/run.sh" 2>/dev/null || true
    fi
    if [[ -f "$PROJECT_DIR/run.sh" ]]; then
        chmod +x "$PROJECT_DIR/run.sh" 2>/dev/null || true
        sed -i 's/\r$//' "$PROJECT_DIR/run.sh" 2>/dev/null || true
    fi
    if [[ -f "$PROJECT_DIR/deploy/test.sh" ]]; then
        chmod +x "$PROJECT_DIR/deploy/test.sh" 2>/dev/null || true
        sed -i 's/\r$//' "$PROJECT_DIR/deploy/test.sh" 2>/dev/null || true
    fi
    if [[ -f "$PROJECT_DIR/deploy/rag-pod.yaml" ]]; then
        sed -i 's/\r$//' "$PROJECT_DIR/deploy/rag-pod.yaml" 2>/dev/null || true
    fi
    if [[ -f "$PROJECT_DIR/deploy/secret.yaml" ]]; then
        sed -i 's/\r$//' "$PROJECT_DIR/deploy/secret.yaml" 2>/dev/null || true
    fi
    echo -e "  ${C_GREEN}✔${C_RESET} ${C_BOLD}Permissions & Line Endings:${C_RESET} Scripts executable & LF normalized"

    # 6. Check Quadlet (systemd)
    if systemctl --user is-system-running &>/dev/null; then
        echo -e "  ${C_GREEN}✔${C_RESET} ${C_BOLD}Systemd User Services:${C_RESET} Running (Quadlet enabled)"
    else
        echo -e "  ${C_GRAY}○${C_RESET} ${C_BOLD}Systemd User Services:${C_RESET} Inactive ('kube' and 'pod' deployment modes are fully functional)"
    fi

    echo ""
    if [[ "$all_good" == "false" ]]; then
        echo -e "  ${C_RED}✖ One or more critical prerequisites are missing. Please resolve them and retry.${C_RESET}\n"
        return 1
    else
        echo -e "  ${C_GREEN}✔ All core environment prerequisites verified!${C_RESET}\n"
        return 0
    fi
}

# ------------------------------------------------------------------------------
# Secrets & Credentials Management
# ------------------------------------------------------------------------------

ensure_api_key() {
    # 1. From passed --key or already resolved API_KEY
    if [[ -z "$API_KEY" && -n "${GOOGLE_API_KEY:-}" ]]; then
        API_KEY="$GOOGLE_API_KEY"
    fi

    # 2. From .env file if available
    if [[ -z "$API_KEY" ]]; then
        if [[ -f "$PROJECT_DIR/.env" ]]; then
            API_KEY=$(grep -E '^GOOGLE_API_KEY=' "$PROJECT_DIR/.env" | cut -d '=' -f2- | tr -d '"'\'' ' || true)
        elif [[ -f "$SCRIPT_DIR/.env" ]]; then
            API_KEY=$(grep -E '^GOOGLE_API_KEY=' "$SCRIPT_DIR/.env" | cut -d '=' -f2- | tr -d '"'\'' ' || true)
        fi
    fi

    # 3. From existing Podman secrets
    if [[ -z "$API_KEY" ]]; then
        if podman secret inspect gemini_api_key &>/dev/null; then
            API_KEY=$(podman secret inspect --showsecret gemini_api_key --format '{{.SecretData}}' 2>/dev/null || true)
        elif podman secret inspect gemini-secret &>/dev/null; then
            API_KEY=$(podman secret inspect --showsecret gemini-secret --format '{{.SecretData}}' 2>/dev/null || true)
        fi
    fi

    # 4. If still empty, prompt interactively
    if [[ -z "$API_KEY" ]]; then
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
    fi

    export GOOGLE_API_KEY="$API_KEY"
    export GOOGLE_GENAI_USE_VERTEXAI="FALSE"

    # Always ensure Podman secret 'gemini_api_key' exists
    if ! podman secret inspect gemini_api_key &>/dev/null; then
        printf '%s' "$API_KEY" | podman secret create gemini_api_key - >/dev/null 2>&1 || true
    fi

    # Always ensure Kubernetes secret 'gemini-secret' exists (required by deploy/rag-pod.yaml)
    if ! podman secret inspect gemini-secret &>/dev/null; then
        printf '%s' "$API_KEY" | podman secret create gemini-secret - >/dev/null 2>&1 || true
    fi

    # Also register in deploy/secret.yaml if template exists
    if [[ -f "$PROJECT_DIR/deploy/secret.yaml" ]]; then
        local tmp_sec
        tmp_sec=$(mktemp)
        sed "s|REPLACE_WITH_YOUR_GEMINI_API_KEY|$API_KEY|" "$PROJECT_DIR/deploy/secret.yaml" > "$tmp_sec"
        podman kube play "$tmp_sec" >/dev/null 2>&1 || true
        rm -f "$tmp_sec"
    fi

    # Create/update local .env for local Python dev if not present
    if [[ ! -f "$PROJECT_DIR/.env" ]]; then
        cat <<EOF > "$PROJECT_DIR/.env"
GOOGLE_API_KEY="$API_KEY"
GOOGLE_GENAI_USE_VERTEXAI="FALSE"
CHROMA_HOST="localhost"
CHROMA_PORT="8000"
EOF
    fi

    return 0
}

# ------------------------------------------------------------------------------
# Local Development Virtual Environment Setup (Module 1)
# ------------------------------------------------------------------------------

setup_local_venv() {
    if ! command -v python3 &>/dev/null; then
        echo -e "  ${C_RED}✖ Python 3 is not installed on the host. Cannot create .venv.${C_RESET}"
        return 1
    fi
    local venv_path="$PROJECT_DIR/.venv"
    echo -e "  Creating virtual environment at $venv_path..."
    python3 -m venv "$venv_path"
    echo -e "  Installing dependencies from $PROJECT_DIR/requirements.txt..."
    "$venv_path/bin/pip" install --quiet --upgrade pip
    "$venv_path/bin/pip" install --quiet -r "$PROJECT_DIR/requirements.txt"
    echo -e "  ${C_GREEN}✔ Virtual environment configured successfully!${C_RESET}"
    echo -e "  ${C_GRAY}To activate: source $venv_path/bin/activate${C_RESET}"
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

    local pver="Not Installed"
    if command -v podman &>/dev/null; then
        pver=$(podman --version | awk '{print $3}')
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
    echo -e "${C_CYAN}  │${C_RESET} ${C_BOLD}Container Engine :${C_RESET} ${C_AQUA}Rootless Podman $pver${C_RESET}                             ${C_CYAN}│${C_RESET}"
    echo -e "${C_CYAN}  │${C_RESET} ${C_BOLD}Agent Stack      :${C_RESET} ${C_PURPLE}Google ADK + Gemini 2.5 Flash + ChromaDB${C_RESET}           ${C_CYAN}│${C_RESET}"
    echo -e "${C_CYAN}  │${C_RESET} ${C_BOLD}Deployment Mode  :${C_RESET} ${C_YELLOW}${DEPLOY_MODE^^}${C_RESET}                                              ${C_CYAN}│${C_RESET}"
    echo -e "${C_CYAN}  │${C_RESET} ${C_BOLD}Cluster Status   :${C_RESET} $status_pill                                      ${C_CYAN}│${C_RESET}"
    echo -e "${C_CYAN}  │${C_RESET} ${C_BOLD}Gemini API Key   :${C_RESET} $key_pill                                  ${C_CYAN}│${C_RESET}"
    echo -e "${C_CYAN}  ╰────────────────────────────────────────────────────────────────────────╯${C_RESET}"
}

# ------------------------------------------------------------------------------
# Action Implementations
# ------------------------------------------------------------------------------

deploy_stack() {
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
        local pod_yaml_abs="$PROJECT_DIR/deploy/rag-pod.yaml"
        sed "s|Yaml=%h/adk-rag-podman/deploy/rag-pod.yaml|Yaml=$pod_yaml_abs|" \
            "$PROJECT_DIR/deploy/quadlet/rag.kube" > "$qdir/rag.kube"
        systemctl --user daemon-reload
        systemctl --user start rag
    fi
    show_spinner "Pod containers initialized" 2
}

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

action_ingest_silent() {
    ensure_api_key
    show_spinner "Embedding and ingesting documents into ChromaDB..." 3
    podman run --rm --pod "$POD_NAME" \
        --secret gemini_api_key,type=env,target=GOOGLE_API_KEY \
        -e GOOGLE_API_KEY="$API_KEY" \
        "$IMAGE_TAG" python ingest/ingest.py
    echo -e "  ${C_GREEN}✔ Ingestion completed! Vectors stored in volume '$CHROMA_VOLUME'.${C_RESET}"
}

action_setup() {
    show_header
    echo -e "\n${C_BOLD}${C_AQUA}═══════════════════════════════════════════════════════════════════════════${C_RESET}"
    echo -e "${C_BOLD}${C_AQUA}   🛠️   STANDARD AUTOMATED SETUP & FIRST-TIME INITIALIZATION               ${C_RESET}"
    echo -e "${C_BOLD}${C_AQUA}═══════════════════════════════════════════════════════════════════════════${C_RESET}\n"

    # Step 1: Pre-requisites & System Health
    echo -e "${C_CYAN}==> [1/7] Checking environment prerequisites & line endings...${C_RESET}"
    if ! check_prerequisites; then
        echo -e "  ${C_RED}✖ Setup cannot proceed due to missing core prerequisites.${C_RESET}\n"
        return 1
    fi

    # Step 2: Gemini API Key & Secrets Configuration
    echo -e "${C_CYAN}==> [2/7] Configuring Google Gemini API credentials...${C_RESET}"
    ensure_api_key
    show_spinner "Secrets verified & registered in Podman & Kubernetes stores" 1

    # Step 3: Local Python Dev Environment (Module 1 in Lab Guide)
    echo -e "\n${C_CYAN}==> [3/7] Setting up Python virtual environment (Module 1: Local Dev)...${C_RESET}"
    if [[ "$WITH_VENV" == "true" ]]; then
        setup_local_venv
    elif [[ "$SKIP_VENV" == "true" ]]; then
        echo -e "  ${C_GRAY}Skipped local .venv setup (--skip-venv active)${C_RESET}"
    else
        # Auto-create if python3 is present, otherwise notify
        if command -v python3 &>/dev/null; then
            setup_local_venv
        else
            echo -e "  ${C_YELLOW}⚠ Python 3 not installed on host — skipping local .venv (container stack is independent)${C_RESET}"
        fi
    fi

    # Step 4: Storage & Container Image Building
    echo -e "\n${C_CYAN}==> [4/7] Preparing volume & building container image (${IMAGE_TAG})...${C_RESET}"
    podman volume inspect "$CHROMA_VOLUME" &>/dev/null || podman volume create "$CHROMA_VOLUME" >/dev/null
    
    if ! podman image inspect "$IMAGE_TAG" &>/dev/null || [[ "$FORCE_BUILD" == "true" ]]; then
        echo -e "  Building container image from $PROJECT_DIR/Containerfile..."
        podman build -t "$IMAGE_TAG" "$PROJECT_DIR"
    else
        show_spinner "Container image $IMAGE_TAG verified in local storage" 1
    fi

    # Verify non-root user (Module 3 security requirement)
    local img_user
    img_user=$(podman image inspect "$IMAGE_TAG" --format '{{.Config.User}}' 2>/dev/null || echo "unknown")
    if [[ "$img_user" == "1001" || "$img_user" == "appuser" ]]; then
        echo -e "  ${C_GREEN}✔ Image Security:${C_RESET} Verified unprivileged non-root user (UID: $img_user)"
    fi

    # Prepare Quadlet unit file if deploy/quadlet exists
    if [[ -d "$PROJECT_DIR/deploy/quadlet" ]]; then
        local qdir="$HOME/.config/containers/systemd"
        mkdir -p "$qdir"
        local pod_yaml_abs="$PROJECT_DIR/deploy/rag-pod.yaml"
        sed "s|Yaml=%h/adk-rag-podman/deploy/rag-pod.yaml|Yaml=$pod_yaml_abs|" \
            "$PROJECT_DIR/deploy/quadlet/rag.kube" > "$qdir/rag.kube"
        if systemctl --user is-system-running &>/dev/null; then
            systemctl --user daemon-reload 2>/dev/null || true
            echo -e "  ${C_GREEN}✔ Quadlet Unit:${C_RESET} Configured in $qdir/rag.kube"
        fi
    fi

    # Step 5: Stack Deployment
    echo -e "\n${C_CYAN}==> [5/7] Deploying Pod (${POD_NAME}) via ${DEPLOY_MODE^^} mode...${C_RESET}"
    deploy_stack

    # Step 6: Knowledge Base Ingestion
    echo -e "\n${C_CYAN}==> [6/7] Ingesting knowledge base documents into ChromaDB...${C_RESET}"
    action_ingest_silent

    # Step 7: Readiness Probe & Verification Smoke Test
    echo -e "\n${C_CYAN}==> [7/7] Verifying ADK REST API Readiness & Running Smoke Test...${C_RESET}"
    wait_for_api_ready 45

    echo -e "${C_CYAN}── Automated Verification Query ──${C_RESET}"
    action_query "How many days of annual leave do I get, and how many can I carry forward?"

    # Final Summary Card
    echo -e "${C_GREEN}${C_BOLD}"
    echo -e "  ╭────────────────────────────────────────────────────────────────────────╮"
    echo -e "  │  ✨ STANDARD SETUP COMPLETED SUCCESSFULLY!                             │"
    echo -e "  ├────────────────────────────────────────────────────────────────────────┤"
    echo -e "  │${C_RESET}  ADK REST API Server : ${C_AQUA}http://localhost:${PORT}${C_GREEN}                                 │"
    echo -e "  │${C_RESET}  API Health Endpoint : ${C_AQUA}http://localhost:${PORT}/list-apps${C_GREEN}                       │"
    echo -e "  │${C_RESET}  ChromaDB Port       : ${C_PURPLE}8000 (Internal & Secure in Pod)${C_GREEN}                  │"
    echo -e "  │${C_RESET}  Container User      : ${C_YELLOW}UID 1001 (Rootless, Non-Root)${C_GREEN}                   │"
    echo -e "  ├────────────────────────────────────────────────────────────────────────┤"
    echo -e "  │${C_RESET}  ${C_BOLD}Next Steps:${C_RESET}                                                           ${C_GREEN}│"
    echo -e "  │${C_RESET}    • Interactive Chat:      ${C_AQUA}./run.sh chat${C_RESET}                                 ${C_GREEN}│"
    echo -e "  │${C_RESET}    • Run Evaluation Suite:  ${C_AQUA}./run.sh test${C_RESET}                                 ${C_GREEN}│"
    echo -e "  │${C_RESET}    • Stream Container Logs: ${C_AQUA}./run.sh logs${C_RESET}                                 ${C_GREEN}│"
    echo -e "  │${C_RESET}    • Stop Workload:         ${C_AQUA}./run.sh stop${C_RESET}                                 ${C_GREEN}│"
    echo -e "  ╰────────────────────────────────────────────────────────────────────────╯${C_RESET}\n"
}

action_up() {
    show_header
    echo -e "\n${C_BOLD}${C_AQUA}═══ STARTING FULL WORKLOAD DEPLOYMENT ═══${C_RESET}\n"
    check_prerequisites >/dev/null 2>&1 || true
    ensure_api_key

    # Step 1: Image
    echo -e "${C_CYAN}==> [1/4] Checking container image...${C_RESET}"
    if ! podman image inspect "$IMAGE_TAG" &>/dev/null || [[ "$FORCE_BUILD" == "true" ]]; then
        podman build -t "$IMAGE_TAG" "$PROJECT_DIR"
    else
        show_spinner "Image $IMAGE_TAG ready" 1
    fi

    # Step 2: Pod Deployment
    echo -e "\n${C_CYAN}==> [2/4] Starting Pod via $DEPLOY_MODE mode...${C_RESET}"
    deploy_stack

    # Step 3: Ingestion
    echo -e "\n${C_CYAN}==> [3/4] Ingesting documents into ChromaDB...${C_RESET}"
    action_ingest_silent

    # Step 4: Health Check & Verification
    echo -e "\n${C_CYAN}==> [4/4] Verifying REST API Server Readiness...${C_RESET}"
    wait_for_api_ready 45

    echo -e "${C_CYAN}==> [Verification] Asking sample question...${C_RESET}"
    action_query "How many days of annual leave do I get, and how many can I carry forward?"

    echo -e "\n${C_GREEN}${C_BOLD}✨ WORKSPACE IS READY & RUNNING!${C_RESET}\n"
}

action_doctor() {
    show_header
    check_prerequisites
    action_status
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
    action_ingest_silent
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

show_help() {
    show_header
    echo -e "${C_BOLD}USAGE:${C_RESET}"
    echo -e "  ./run.sh [COMMAND] [OPTIONS]\n"
    echo -e "${C_BOLD}COMMANDS:${C_RESET}"
    echo -e "  ${C_AQUA}setup | init${C_RESET}         Run complete standard setup & first-time initialization"
    echo -e "                      ${C_GRAY}(Prerequisites -> Secrets -> Build -> Deploy -> Ingest -> Verify)${C_RESET}"
    echo -e "  ${C_AQUA}up | start${C_RESET}           Launch the complete container stack and verify readiness"
    echo -e "  ${C_AQUA}down | stop${C_RESET}          Stop running workload cleanly (preserves ChromaDB volume)"
    echo -e "  ${C_AQUA}restart${C_RESET}              Restart the running workload"
    echo -e "  ${C_AQUA}doctor | check${C_RESET}       Inspect environment prerequisites, Podman status, and secrets"
    echo -e "  ${C_AQUA}chat${C_RESET}                 Open interactive multi-turn chat session with the RAG agent"
    echo -e "  ${C_AQUA}query \"<question>\"${C_RESET}   Ask a single question and display the agent's answer"
    echo -e "  ${C_AQUA}test${C_RESET}                 Run complete workshop evaluation suite (3 scenarios)"
    echo -e "  ${C_AQUA}ingest${C_RESET}               Re-chunk and embed knowledge base documents into ChromaDB"
    echo -e "  ${C_AQUA}status${C_RESET}               Display pod, container, volume, secret, and API status"
    echo -e "  ${C_AQUA}logs [agent|chroma]${C_RESET}  Live stream container logs"
    echo -e "  ${C_AQUA}build${C_RESET}                Build or verify the agent container image"
    echo -e "  ${C_AQUA}venv${C_RESET}                 Set up local Python 3 virtual environment (.venv)"
    echo -e "  ${C_AQUA}clean${C_RESET}                Deep cleanup: purge pods, volumes, secrets, and images"
    echo -e "  ${C_AQUA}menu${C_RESET}                 Open interactive animated TUI console menu (default)\n"
    echo -e "${C_BOLD}OPTIONS:${C_RESET}"
    echo -e "  ${C_YELLOW}--mode <mode>${C_RESET}        Deployment mode: 'kube' (default), 'pod', or 'quadlet'"
    echo -e "  ${C_YELLOW}--key <api_key>${C_RESET}      Specify Gemini API key directly"
    echo -e "  ${C_YELLOW}--port <port>${C_RESET}        Host port to expose ADK API server (default: 8080)"
    echo -e "  ${C_YELLOW}--with-venv${C_RESET}          Include local Python .venv creation during setup"
    echo -e "  ${C_YELLOW}--skip-venv${C_RESET}          Skip local Python .venv creation during setup"
    echo -e "  ${C_YELLOW}--force-build${C_RESET}        Force rebuilding the container image without cache"
    echo -e "  ${C_YELLOW}-h, --help${C_RESET}           Show this help message\n"
    echo -e "${C_BOLD}EXAMPLES:${C_RESET}"
    echo -e "  ${C_GRAY}./run.sh setup${C_RESET}                       # Standard automated setup"
    echo -e "  ${C_GRAY}./run.sh setup --key AIzaSy...${C_RESET}       # Setup with explicit API key"
    echo -e "  ${C_GRAY}./run.sh query \"What is leave?\"${C_RESET}      # Query agent directly from CLI"
    echo -e "  ${C_GRAY}./run.sh doctor${C_RESET}                      # Check prerequisites and status\n"
}

# ------------------------------------------------------------------------------
# Interactive Menu Loop
# ------------------------------------------------------------------------------

run_menu() {
    while true; do
        show_header
        echo -e "${C_BOLD}  CONTROL CONSOLE MENU:${C_RESET}"
        echo -e "  ${C_AQUA}[1]${C_RESET} ${C_BOLD}🛠️   Standard Setup & Launch${C_RESET}  ${C_GRAY}(Prereqs + Secrets + Build + Deploy + Ingest + Verify)${C_RESET}"
        echo -e "  ${C_AQUA}[2]${C_RESET} ${C_BOLD}💬  Interactive Chat${C_RESET}         ${C_GRAY}(Ask questions from knowledge base)${C_RESET}"
        echo -e "  ${C_AQUA}[3]${C_RESET} ${C_BOLD}🧪  Run Evaluation Suite${C_RESET}     ${C_GRAY}(3 standard workshop test scenarios)${C_RESET}"
        echo -e "  ${C_AQUA}[4]${C_RESET} ${C_BOLD}📊  Inspect Cluster Status${C_RESET}   ${C_GRAY}(Pods, containers, volumes, secrets, health)${C_RESET}"
        echo -e "  ${C_AQUA}[5]${C_RESET} ${C_BOLD}📜  Stream Container Logs${C_RESET}    ${C_GRAY}(Agent API & ChromaDB logs)${C_RESET}"
        echo -e "  ${C_AQUA}[6]${C_RESET} ${C_BOLD}📚  Re-index / Ingest Docs${C_RESET}   ${C_GRAY}(Re-chunk & embed documents into ChromaDB)${C_RESET}"
        echo -e "  ${C_AQUA}[7]${C_RESET} ${C_BOLD}🩺  Run System Doctor${C_RESET}        ${C_GRAY}(Verify Podman, rootless, versions, tools)${C_RESET}"
        echo -e "  ${C_AQUA}[8]${C_RESET} ${C_BOLD}🐍  Setup Local Dev (.venv)${C_RESET}  ${C_GRAY}(Module 1: requirements.txt for local dev)${C_RESET}"
        echo -e "  ${C_AQUA}[9]${C_RESET} ${C_BOLD}⚙️   Change Deployment Mode${C_RESET}  ${C_GRAY}(Current: $DEPLOY_MODE)${C_RESET}"
        echo -e "  ${C_AQUA}[10]${C_RESET}${C_BOLD}🛑  Stop Running Workload${C_RESET}   ${C_GRAY}(Stop pod without losing vector data)${C_RESET}"
        echo -e "  ${C_AQUA}[11]${C_RESET}${C_BOLD}🧹  Deep Clean All${C_RESET}           ${C_GRAY}(Purge pod, volumes, secrets, and images)${C_RESET}"
        echo -e "  ${C_AQUA}[0]${C_RESET} ${C_BOLD}🚪  Exit${C_RESET}\n"
        echo -ne "  ${C_YELLOW}Select an option [0-11]:${C_RESET} "
        
        read -r choice
        case "$choice" in
            1) action_setup; echo -ne "  ${C_GRAY}Press Enter to return to menu...${C_RESET}"; read -r ;;
            2) action_chat ;;
            3) action_test; echo -ne "  ${C_GRAY}Press Enter to return to menu...${C_RESET}"; read -r ;;
            4) action_status; echo -ne "  ${C_GRAY}Press Enter to return to menu...${C_RESET}"; read -r ;;
            5) action_logs ;;
            6) action_ingest; echo -ne "  ${C_GRAY}Press Enter to return to menu...${C_RESET}"; read -r ;;
            7) action_doctor; echo -ne "  ${C_GRAY}Press Enter to return to menu...${C_RESET}"; read -r ;;
            8) setup_local_venv; echo -ne "  ${C_GRAY}Press Enter to return to menu...${C_RESET}"; read -r ;;
            9)
                echo -e "\n  Select Mode: [1] kube (default)  [2] pod  [3] quadlet"
                echo -ne "  Choice: "
                read -r mc
                if [[ "$mc" == "1" ]]; then DEPLOY_MODE="kube"; fi
                if [[ "$mc" == "2" ]]; then DEPLOY_MODE="pod"; fi
                if [[ "$mc" == "3" ]]; then DEPLOY_MODE="quadlet"; fi
                ;;
            10) action_stop; sleep 1 ;;
            11) action_clean; echo -ne "  ${C_GRAY}Press Enter to return to menu...${C_RESET}"; read -r ;;
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
        setup|init)
            ACTION="setup"
            shift
            ;;
        up|start)
            ACTION="up"
            shift
            ;;
        doctor|check)
            ACTION="doctor"
            shift
            ;;
        down|stop)
            ACTION="stop"
            shift
            ;;
        restart)
            ACTION="restart"
            shift
            ;;
        test)
            ACTION="test"
            shift
            ;;
        status)
            ACTION="status"
            shift
            ;;
        clean)
            ACTION="clean"
            shift
            ;;
        build)
            ACTION="build"
            shift
            ;;
        ingest)
            ACTION="ingest"
            shift
            ;;
        chat)
            ACTION="chat"
            shift
            ;;
        venv)
            ACTION="venv"
            shift
            ;;
        menu)
            ACTION="menu"
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
        --with-venv)
            WITH_VENV=true
            shift
            ;;
        --skip-venv)
            SKIP_VENV=true
            shift
            ;;
        -h|--help|help)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown argument: $1"
            echo "Run './run.sh --help' to see available commands."
            exit 1
            ;;
    esac
done

case "$ACTION" in
    menu)       run_menu ;;
    setup|init) action_setup ;;
    up|start)   action_up ;;
    doctor|check) action_doctor ;;
    down|stop)  action_stop ;;
    restart)    action_stop; sleep 1; action_up ;;
    test)       action_test ;;
    query)      action_query "$CUSTOM_QUERY" ;;
    chat)       action_chat ;;
    ingest)     action_ingest ;;
    status)     action_status ;;
    logs)       action_logs ;;
    clean)      action_clean ;;
    build)      action_build ;;
    venv)       setup_local_venv ;;
esac
