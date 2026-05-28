#!/usr/bin/env bash
set -Eeuo pipefail

# KaliArc AI Lab
# Installs Docker, Ollama, Open WebUI, local agent runner, local MCP server,
# and optional HexStrike MCP wiring for authorised lab use only.

STACK_DIR="${STACK_DIR:-$HOME/kaliarc-ai-lab}"
BIND_ADDR="${BIND_ADDR:-127.0.0.1}"
PRIMARY_MODEL="${PRIMARY_MODEL:-gemma3:latest}"
FULL_STACK=1
WITH_HEXSTRIKE=0
START_HEXSTRIKE=0
GPU=0
ADD_DOCKER_GROUP=0
INSTALL_KALI_HELPERS=1
SKIP_MODEL_PULL=0
CUSTOM_MODELS=""

usage() {
  cat <<EOF
Usage:
  ./setup.sh [options]
  ./install.sh [options]

Core options:
  --model MODEL              Primary Ollama model. Default: gemma3:latest
  --models CSV               Override model pulls with comma-separated list
  --lite                     Only Ollama + Open WebUI + local agents + safe MCP
  --full                     Full stack: LiteLLM, Qdrant, SearXNG, n8n, Flowise
  --skip-model-pull          Do not pull Ollama models during setup
  --gpu                      Add Docker Compose GPU hint for Ollama

Security / convenience:
  --bind ADDR                Bind service ports. Default: 127.0.0.1
  --add-user-to-docker       Add current user to docker group
  --no-kali-helpers          Do not install optional Kali helper tools

HexStrike:
  --with-hexstrike           Install Kali hexstrike-ai package and MCP config
  --start-hexstrike          Start HexStrike local API on 127.0.0.1:8888

Examples:
  ./setup.sh --full --with-hexstrike
  ./setup.sh --model llama3:latest --full
  ./setup.sh --models llama3:latest,mistral:latest,qwen2.5-coder:7b --gpu
EOF
}

log()  { printf "\033[1;32m[+]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[!]\033[0m %s\n" "$*" >&2; }
die()  { printf "\033[1;31m[x]\033[0m %s\n" "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)
      PRIMARY_MODEL="${2:?Missing model after --model}"
      shift 2
      ;;
    --models)
      CUSTOM_MODELS="${2:?Missing CSV list after --models}"
      shift 2
      ;;
    --lite)
      FULL_STACK=0
      shift
      ;;
    --full)
      FULL_STACK=1
      shift
      ;;
    --skip-model-pull)
      SKIP_MODEL_PULL=1
      shift
      ;;
    --gpu)
      GPU=1
      shift
      ;;
    --bind)
      BIND_ADDR="${2:?Missing bind address after --bind}"
      shift 2
      ;;
    --add-user-to-docker)
      ADD_DOCKER_GROUP=1
      shift
      ;;
    --no-kali-helpers)
      INSTALL_KALI_HELPERS=0
      shift
      ;;
    --with-hexstrike)
      WITH_HEXSTRIKE=1
      shift
      ;;
    --start-hexstrike)
      WITH_HEXSTRIKE=1
      START_HEXSTRIKE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

[[ "$(uname -s)" == "Linux" ]] || die "This script is intended for Linux/Kali."
sudo -v

mkdir -p "$STACK_DIR"/{agents,mcp,bin,config/litellm,config/searxng,data,logs,backups}
chmod 700 "$STACK_DIR"

ENV_FILE="$STACK_DIR/.env"
COMPOSE_FILE="$STACK_DIR/docker-compose.yml"

randhex() {
  openssl rand -hex 32
}

secret_or_new() {
  local key="$1"
  local value=""
  if [[ -f "$ENV_FILE" ]]; then
    value="$(grep -E "^${key}=" "$ENV_FILE" | tail -n1 | cut -d= -f2- || true)"
  fi
  if [[ -z "$value" ]]; then
    value="$(randhex)"
  fi
  printf '%s' "$value"
}

WEBUI_SECRET_KEY="$(secret_or_new WEBUI_SECRET_KEY)"
LITELLM_MASTER_KEY="$(secret_or_new LITELLM_MASTER_KEY)"
N8N_PASSWORD="$(secret_or_new N8N_PASSWORD)"
FLOWISE_PASSWORD="$(secret_or_new FLOWISE_PASSWORD)"
SEARXNG_SECRET="$(secret_or_new SEARXNG_SECRET)"

cat > "$ENV_FILE" <<EOF
BIND_ADDR=$BIND_ADDR
PRIMARY_MODEL=$PRIMARY_MODEL
WEBUI_SECRET_KEY=$WEBUI_SECRET_KEY
LITELLM_MASTER_KEY=$LITELLM_MASTER_KEY
N8N_USER=admin
N8N_PASSWORD=$N8N_PASSWORD
FLOWISE_USERNAME=admin
FLOWISE_PASSWORD=$FLOWISE_PASSWORD
SEARXNG_SECRET=$SEARXNG_SECRET
EOF
chmod 600 "$ENV_FILE"

resource_check() {
  local mem_gb disk_gb
  mem_gb="$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 0)"
  disk_gb="$(df -BG "$HOME" | awk 'NR==2 {gsub("G","",$4); print $4}' 2>/dev/null || echo 0)"
  if [[ "$mem_gb" -lt 8 ]]; then
    warn "RAM appears to be ${mem_gb}GB. Smaller models are recommended."
  fi
  if [[ "$disk_gb" -lt 35 ]]; then
    warn "Free disk appears to be ${disk_gb}GB. Model pulls may fail if storage is low."
  fi
}

install_base_packages() {
  log "Updating apt and installing Docker/base dependencies"
  sudo apt-get update
  sudo apt-get install -y \
    ca-certificates \
    curl \
    git \
    jq \
    openssl \
    python3 \
    python3-venv \
    python3-pip \
    docker.io

  sudo systemctl enable --now docker

  if ! sudo docker compose version >/dev/null 2>&1; then
    warn "Docker Compose plugin not found. Trying Kali/Debian package names."
    sudo apt-get install -y docker-compose-plugin || \
    sudo apt-get install -y docker-compose-v2 || \
    die "Could not install Docker Compose v2. Install it manually, then rerun."
  fi

  if [[ "$ADD_DOCKER_GROUP" -eq 1 ]]; then
    sudo usermod -aG docker "$USER"
    warn "User $USER added to docker group. Log out and back in for non-sudo docker use."
  fi
}

install_kali_helpers() {
  [[ "$INSTALL_KALI_HELPERS" -eq 1 ]] || return 0
  log "Installing optional local-lab helper tools"
  local packages=(
    tmux htop ripgrep fzf httpie
    dnsutils whois net-tools iproute2 iputils-ping traceroute
    nmap whatweb nikto feroxbuster nuclei
    gobuster dirb wafw00f sslscan testssl.sh
    python3-requests python3-bs4
  )
  for pkg in "${packages[@]}"; do
    sudo apt-get install -y "$pkg" >/dev/null 2>&1 || warn "Optional package not installed or unavailable: $pkg"
  done
}

write_compose() {
  log "Writing Docker Compose stack"

  local gpu_block=""
  if [[ "$GPU" -eq 1 ]]; then
    gpu_block="    gpus: all"
    warn "GPU mode requested. Host NVIDIA drivers and NVIDIA Container Toolkit must already be working."
  fi

  cat > "$COMPOSE_FILE" <<EOF
name: kaliarc-ai-lab

services:
  ollama:
    image: ollama/ollama:latest
    container_name: kali-ai-ollama
    restart: unless-stopped
    ports:
      - "\${BIND_ADDR:-127.0.0.1}:11434:11434"
    volumes:
      - ollama:/root/.ollama
$gpu_block
    healthcheck:
      test: ["CMD", "ollama", "list"]
      interval: 30s
      timeout: 10s
      retries: 10

  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: kali-ai-open-webui
    restart: unless-stopped
    depends_on:
      - ollama
    ports:
      - "\${BIND_ADDR:-127.0.0.1}:3000:8080"
    environment:
      OLLAMA_BASE_URL: "http://ollama:11434"
      WEBUI_AUTH: "true"
      WEBUI_SECRET_KEY: "\${WEBUI_SECRET_KEY}"
      ENABLE_RAG_WEB_SEARCH: "true"
      RAG_WEB_SEARCH_ENGINE: "searxng"
      SEARXNG_QUERY_URL: "http://searxng:8080/search?q=<query>&format=json"
      QDRANT_URI: "http://qdrant:6333"
    volumes:
      - open-webui:/app/backend/data

  litellm:
    image: ghcr.io/berriai/litellm:main-latest
    container_name: kali-ai-litellm
    restart: unless-stopped
    profiles: ["extras"]
    depends_on:
      - ollama
    ports:
      - "\${BIND_ADDR:-127.0.0.1}:4000:4000"
    environment:
      LITELLM_MASTER_KEY: "\${LITELLM_MASTER_KEY}"
    command: ["--config", "/app/config.yaml", "--host", "0.0.0.0", "--port", "4000"]
    volumes:
      - ./config/litellm/config.yaml:/app/config.yaml:ro

  qdrant:
    image: qdrant/qdrant:latest
    container_name: kali-ai-qdrant
    restart: unless-stopped
    profiles: ["extras"]
    ports:
      - "\${BIND_ADDR:-127.0.0.1}:6333:6333"
    volumes:
      - qdrant:/qdrant/storage

  searxng:
    image: searxng/searxng:latest
    container_name: kali-ai-searxng
    restart: unless-stopped
    profiles: ["extras"]
    ports:
      - "\${BIND_ADDR:-127.0.0.1}:8088:8080"
    environment:
      SEARXNG_BASE_URL: "http://\${BIND_ADDR:-127.0.0.1}:8088/"
      SEARXNG_SECRET: "\${SEARXNG_SECRET}"
    volumes:
      - ./config/searxng:/etc/searxng:rw

  n8n:
    image: docker.n8n.io/n8nio/n8n:latest
    container_name: kali-ai-n8n
    restart: unless-stopped
    profiles: ["extras"]
    ports:
      - "\${BIND_ADDR:-127.0.0.1}:5678:5678"
    environment:
      N8N_BASIC_AUTH_ACTIVE: "true"
      N8N_BASIC_AUTH_USER: "\${N8N_USER}"
      N8N_BASIC_AUTH_PASSWORD: "\${N8N_PASSWORD}"
      N8N_HOST: "\${BIND_ADDR:-127.0.0.1}"
      N8N_PROTOCOL: "http"
      WEBHOOK_URL: "http://\${BIND_ADDR:-127.0.0.1}:5678/"
      GENERIC_TIMEZONE: "Australia/Brisbane"
    volumes:
      - n8n:/home/node/.n8n

  flowise:
    image: flowiseai/flowise:latest
    container_name: kali-ai-flowise
    restart: unless-stopped
    profiles: ["extras"]
    ports:
      - "\${BIND_ADDR:-127.0.0.1}:3001:3000"
    environment:
      FLOWISE_USERNAME: "\${FLOWISE_USERNAME}"
      FLOWISE_PASSWORD: "\${FLOWISE_PASSWORD}"
    volumes:
      - flowise:/root/.flowise
    command: /bin/sh -c "sleep 3; flowise start"

volumes:
  ollama:
  open-webui:
  qdrant:
  n8n:
  flowise:
EOF
}

write_litellm_config() {
  cat > "$STACK_DIR/config/litellm/config.yaml" <<EOF
model_list:
  - model_name: llama3
    litellm_params:
      model: ollama/llama3:latest
      api_base: http://ollama:11434
  - model_name: mistral
    litellm_params:
      model: ollama/mistral:latest
      api_base: http://ollama:11434
  - model_name: primary
    litellm_params:
      model: ollama/$PRIMARY_MODEL
      api_base: http://ollama:11434
  - model_name: coder
    litellm_params:
      model: ollama/qwen2.5-coder:7b
      api_base: http://ollama:11434

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  telemetry: false
EOF
}

write_searxng_config() {
  cat > "$STACK_DIR/config/searxng/settings.yml" <<'EOF'
use_default_settings: true

server:
  bind_address: "0.0.0.0"
  port: 8080
  secret_key: "change-me-generated-by-env"
  limiter: false
  image_proxy: true

search:
  safe_search: 0
  autocomplete: ""
  formats:
    - html
    - json

ui:
  static_use_hash: true
EOF
}

write_local_agents() {
  log "Writing local multi-agent runner"

  cat > "$STACK_DIR/agents/local_agents.py" <<'PY'
#!/usr/bin/env python3
import argparse
import datetime as dt
import json
import os
import sys
import textwrap
import urllib.error
import urllib.request
from pathlib import Path

OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434/api/chat")
DEFAULT_PRIMARY = os.environ.get("MODEL", os.environ.get("PRIMARY_MODEL", "gemma3:latest"))
OUT_DIR = Path(os.environ.get("AGENT_OUT_DIR", str(Path.home() / "kaliarc-ai-lab" / "logs")))

ROLE_CONFIG = [
    {
        "name": "Planner",
        "model": os.environ.get("PLANNER_MODEL", "llama3:latest"),
        "system": (
            "You are a local planning agent for Kali/Linux/dev/security lab work. "
            "Break tasks into clear authorised steps. Keep scope local or explicitly authorised. "
            "Do not create malware, phishing kits, credential theft workflows, stealth/persistence, or unauthorised exploitation."
        ),
    },
    {
        "name": "Builder",
        "model": os.environ.get("BUILDER_MODEL", DEFAULT_PRIMARY),
        "system": (
            "You are a local builder/coder agent. Produce practical scripts, commands, config, and tests. "
            "Default to localhost/lab-safe settings, input validation, logs, and rollback commands."
        ),
    },
    {
        "name": "Reviewer",
        "model": os.environ.get("REVIEWER_MODEL", "mistral:latest"),
        "system": (
            "You are a strict reviewer. Find bugs, risky assumptions, missing dependencies, "
            "unsafe network exposure, weak secrets, and operational issues. Provide concise fixes."
        ),
    },
    {
        "name": "Reporter",
        "model": os.environ.get("REPORTER_MODEL", DEFAULT_PRIMARY),
        "system": (
            "You are a reporting agent. Summarise the final plan, commands, verification checks, "
            "and files created. Keep it direct."
        ),
    },
]

def call_ollama(model: str, system: str, user: str) -> str:
    payload = {
        "model": model,
        "stream": False,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "options": {
            "temperature": 0.2,
            "num_ctx": 8192,
        },
    }
    req = urllib.request.Request(
        OLLAMA_URL,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=900) as response:
            data = json.loads(response.read().decode("utf-8"))
            return data.get("message", {}).get("content", "").strip()
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Ollama HTTP error {exc.code}: {body}") from exc
    except Exception as exc:
        raise RuntimeError(f"Ollama request failed for model {model}: {exc}") from exc

def main() -> int:
    parser = argparse.ArgumentParser(description="Run a local multi-agent Ollama workflow.")
    parser.add_argument("task", nargs="+", help="Task for the local agents")
    parser.add_argument("--save", action="store_true", help="Save markdown report to logs directory")
    args = parser.parse_args()

    task = " ".join(args.task).strip()
    context = f"Original task:\n{task}\n"
    report_parts = [f"# Local Agent Report\n\nTask: {task}\n"]

    for role in ROLE_CONFIG:
        heading = f"===== {role['name']} [{role['model']}] ====="
        print(f"\n{heading}\n")
        output = call_ollama(role["model"], role["system"], context)
        print(output)
        context += f"\n\n{role['name']} output:\n{output}\n"
        report_parts.append(f"\n## {role['name']} [{role['model']}]\n\n{output}\n")

    if args.save:
        OUT_DIR.mkdir(parents=True, exist_ok=True)
        stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        path = OUT_DIR / f"agent-report-{stamp}.md"
        path.write_text("\n".join(report_parts), encoding="utf-8")
        print(f"\nSaved: {path}")

    return 0

if __name__ == "__main__":
    raise SystemExit(main())
PY

  chmod +x "$STACK_DIR/agents/local_agents.py"

  cat > "$STACK_DIR/bin/agent.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
export PRIMARY_MODEL="$PRIMARY_MODEL"
exec python3 "$STACK_DIR/agents/local_agents.py" "\$@"
EOF
  chmod +x "$STACK_DIR/bin/agent.sh"
}

write_safe_mcp_server() {
  log "Writing safe local MCP server"

  cat > "$STACK_DIR/mcp/safe_local_mcp.py" <<'PY'
#!/usr/bin/env python3
import os
import pathlib
import subprocess
from typing import List

try:
    from mcp.server.fastmcp import FastMCP
except Exception as exc:
    raise SystemExit(
        "Missing Python package 'mcp'. Run:\n"
        "  python3 -m venv ~/kaliarc-ai-lab/mcp/.venv\n"
        "  ~/kaliarc-ai-lab/mcp/.venv/bin/python -m pip install mcp\n"
        f"Original error: {exc}"
    )

LAB_ROOT = pathlib.Path(os.environ.get("KALI_AI_LAB_ROOT", pathlib.Path.home() / "kaliarc-ai-lab")).resolve()
mcp = FastMCP("kali-safe-local-tools")

def run_cmd(argv: List[str], timeout: int = 20) -> str:
    result = subprocess.run(
        argv,
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )
    out = result.stdout.strip()
    err = result.stderr.strip()
    body = out if out else ""
    if err:
        body += ("\n\nSTDERR:\n" + err)
    return body[:12000] if body else f"Command exited with code {result.returncode}"

@mcp.tool()
def system_summary() -> str:
    """Return basic local system information."""
    chunks = []
    for argv in (["uname", "-a"], ["free", "-h"], ["df", "-h", str(LAB_ROOT)], ["ip", "-brief", "addr"]):
        chunks.append(f"$ {' '.join(argv)}\n{run_cmd(argv)}")
    return "\n\n".join(chunks)

@mcp.tool()
def ollama_models() -> str:
    """List locally installed Ollama models."""
    return run_cmd(["curl", "-fsS", "http://127.0.0.1:11434/api/tags"], timeout=20)

@mcp.tool()
def docker_lab_status() -> str:
    """Show Docker containers in this local AI lab."""
    return run_cmd(["docker", "ps", "--filter", "name=kali-ai", "--format", "table {{.Names}}\t{{.Status}}\t{{.Ports}}"], timeout=20)

@mcp.tool()
def read_lab_file(relative_path: str) -> str:
    """Read a text file under the Kali AI lab directory only."""
    target = (LAB_ROOT / relative_path).resolve()
    if not str(target).startswith(str(LAB_ROOT)):
        return "Denied: path is outside the lab directory."
    if not target.exists() or not target.is_file():
        return "File not found."
    data = target.read_text(encoding="utf-8", errors="replace")
    return data[:12000]

if __name__ == "__main__":
    mcp.run()
PY

  chmod +x "$STACK_DIR/mcp/safe_local_mcp.py"

  log "Creating MCP Python venv"
  python3 -m venv "$STACK_DIR/mcp/.venv"
  if ! "$STACK_DIR/mcp/.venv/bin/python" -m pip install --upgrade pip wheel >/dev/null 2>&1; then
    warn "Could not upgrade pip in MCP venv."
  fi
  if ! "$STACK_DIR/mcp/.venv/bin/python" -m pip install mcp >/dev/null 2>&1; then
    warn "Could not install Python MCP package. Retry manually:"
    warn "$STACK_DIR/mcp/.venv/bin/python -m pip install mcp"
  fi
}

write_mcp_config() {
  local hex_block=""
  if [[ "$WITH_HEXSTRIKE" -eq 1 ]]; then
    hex_block='
    ,
    "hexstrike-local": {
      "command": "hexstrike_mcp",
      "args": [
        "--server",
        "http://127.0.0.1:8888",
        "--timeout",
        "300"
      ]
    }'
  fi

  cat > "$STACK_DIR/mcp/mcp.local.json" <<EOF
{
  "mcpServers": {
    "kali-safe-local": {
      "command": "$STACK_DIR/mcp/.venv/bin/python",
      "args": [
        "$STACK_DIR/mcp/safe_local_mcp.py"
      ],
      "env": {
        "KALI_AI_LAB_ROOT": "$STACK_DIR"
      }
    }$hex_block
  }
}
EOF

  cat > "$STACK_DIR/mcp/README.md" <<EOF
# MCP configs

Main config:

\`\`\`
$STACK_DIR/mcp/mcp.local.json
\`\`\`

Included MCP servers:

- \`kali-safe-local\`: safe local system/lab inspection tools.
- \`hexstrike-local\`: only present when installed with \`--with-hexstrike\`.

HexStrike server, when used, is expected at:

\`\`\`
http://127.0.0.1:8888
\`\`\`
EOF
}

install_hexstrike() {
  [[ "$WITH_HEXSTRIKE" -eq 1 ]] || return 0

  log "Installing HexStrike AI from Kali repo"
  sudo apt-get install -y hexstrike-ai || die "Could not install hexstrike-ai from apt."

  cat > "$STACK_DIR/bin/start-hexstrike-local.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
mkdir -p "$STACK_DIR/logs"
if pgrep -f "hexstrike_server.*--port 8888" >/dev/null 2>&1; then
  echo "[+] HexStrike appears to already be running on port 8888"
  exit 0
fi
echo "[+] Starting HexStrike local API on 127.0.0.1:8888"
nohup hexstrike_server --port 8888 > "$STACK_DIR/logs/hexstrike.log" 2>&1 &
echo \$! > "$STACK_DIR/logs/hexstrike.pid"
echo "[+] PID: \$(cat "$STACK_DIR/logs/hexstrike.pid")"
echo "[+] Log: $STACK_DIR/logs/hexstrike.log"
EOF
  chmod +x "$STACK_DIR/bin/start-hexstrike-local.sh"

  cat > "$STACK_DIR/bin/stop-hexstrike-local.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
PIDFILE="$STACK_DIR/logs/hexstrike.pid"
if [[ -f "\$PIDFILE" ]]; then
  kill "\$(cat "\$PIDFILE")" 2>/dev/null || true
  rm -f "\$PIDFILE"
fi
pkill -f "hexstrike_server.*--port 8888" 2>/dev/null || true
echo "[+] HexStrike stopped"
EOF
  chmod +x "$STACK_DIR/bin/stop-hexstrike-local.sh"

  if [[ "$START_HEXSTRIKE" -eq 1 ]]; then
    "$STACK_DIR/bin/start-hexstrike-local.sh" || warn "HexStrike did not start. Check logs."
  else
    warn "HexStrike installed but not started. Start it with: $STACK_DIR/bin/start-hexstrike-local.sh"
  fi
}

start_stack() {
  log "Starting Docker services"
  if [[ "$FULL_STACK" -eq 1 ]]; then
    sudo docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" --profile extras up -d
  else
    sudo docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d ollama open-webui
  fi
}

wait_for_ollama() {
  log "Waiting for Ollama API"
  for _ in {1..60}; do
    if curl -fsS "http://$BIND_ADDR:11434/api/tags" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  warn "Ollama did not respond yet. Model pulls may fail."
  return 1
}

models_to_pull() {
  if [[ -n "$CUSTOM_MODELS" ]]; then
    IFS=',' read -r -a MODELS <<< "$CUSTOM_MODELS"
  else
    MODELS=(
      "$PRIMARY_MODEL"
      "llama3:latest"
      "mistral:latest"
      "qwen2.5-coder:7b"
      "nomic-embed-text:latest"
    )
  fi

  local seen=""
  for model in "${MODELS[@]}"; do
    model="$(echo "$model" | xargs)"
    [[ -z "$model" ]] && continue
    if [[ "$seen" != *"|$model|"* ]]; then
      echo "$model"
      seen+="|$model|"
    fi
  done
}

pull_models() {
  [[ "$SKIP_MODEL_PULL" -eq 0 ]] || {
    warn "Skipping model pulls."
    return 0
  }

  wait_for_ollama || true

  log "Pulling Ollama models"
  while IFS= read -r model; do
    [[ -z "$model" ]] && continue
    log "ollama pull $model"
    if ! sudo docker exec kali-ai-ollama ollama pull "$model"; then
      warn "Model pull failed: $model"
      warn "Retry: sudo docker exec kali-ai-ollama ollama pull $model"
    fi
  done < <(models_to_pull)
}

write_management_scripts() {
  log "Writing management scripts"

  cat > "$STACK_DIR/bin/start.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "$FULL_STACK" -eq 1 ]]; then
  sudo docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" --profile extras up -d
else
  sudo docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d ollama open-webui
fi
EOF

  cat > "$STACK_DIR/bin/stop.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
sudo docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" down
EOF

  cat > "$STACK_DIR/bin/restart.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
"$STACK_DIR/bin/stop.sh"
"$STACK_DIR/bin/start.sh"
EOF

  cat > "$STACK_DIR/bin/status.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
echo "== Docker containers =="
sudo docker ps --filter "name=kali-ai" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo
echo "== Ollama models =="
curl -fsS "http://$BIND_ADDR:11434/api/tags" | jq . || true
echo
echo "== URLs =="
echo "Open WebUI:  http://$BIND_ADDR:3000"
echo "Ollama API:   http://$BIND_ADDR:11434"
if [[ "$FULL_STACK" -eq 1 ]]; then
  echo "LiteLLM API:  http://$BIND_ADDR:4000"
  echo "SearXNG:      http://$BIND_ADDR:8088"
  echo "n8n:          http://$BIND_ADDR:5678"
  echo "Flowise:      http://$BIND_ADDR:3001"
  echo "Qdrant:       http://$BIND_ADDR:6333/dashboard"
fi
echo
echo "== Secrets =="
echo "Stored in: $ENV_FILE"
echo
echo "== MCP config =="
echo "$STACK_DIR/mcp/mcp.local.json"
EOF

  cat > "$STACK_DIR/bin/pull-models.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
MODELS=( "\$@" )
if [[ "\${#MODELS[@]}" -eq 0 ]]; then
  MODELS=( "$PRIMARY_MODEL" "llama3:latest" "mistral:latest" "qwen2.5-coder:7b" "nomic-embed-text:latest" )
fi
for model in "\${MODELS[@]}"; do
  echo "[+] Pulling \$model"
  sudo docker exec kali-ai-ollama ollama pull "\$model"
done
EOF

  cat > "$STACK_DIR/bin/update.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
sudo apt-get update
sudo apt-get install -y docker.io
sudo docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" pull
"$STACK_DIR/bin/start.sh"
"$STACK_DIR/bin/pull-models.sh"
EOF

  cat > "$STACK_DIR/bin/backup-volumes.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
STAMP=\$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="$STACK_DIR/backups/\$STAMP"
mkdir -p "\$BACKUP_DIR"

for volume in ollama open-webui qdrant n8n flowise; do
  docker_volume="kaliarc-ai-lab_\$volume"
  if sudo docker volume inspect "\$docker_volume" >/dev/null 2>&1; then
    echo "[+] Backing up \$docker_volume"
    sudo docker run --rm -v "\$docker_volume:/volume:ro" -v "\$BACKUP_DIR:/backup" alpine \
      tar czf "/backup/\$volume.tgz" -C /volume .
  fi
done

tar czf "\$BACKUP_DIR/configs.tgz" -C "$STACK_DIR" \
  docker-compose.yml config agents mcp bin README.md .env

echo "[+] Backup written to \$BACKUP_DIR"
EOF

  cat > "$STACK_DIR/bin/uninstall.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
echo "This stops and removes containers. Volumes are kept unless you pass --volumes."
sudo docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" down
if [[ "\${1:-}" == "--volumes" ]]; then
  sudo docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" down -v
fi
EOF

  chmod +x "$STACK_DIR/bin/"*.sh
}

write_readme() {
  cat > "$STACK_DIR/README.md" <<EOF
# KaliArc AI Lab

## Local URLs

- Open WebUI: http://$BIND_ADDR:3000
- Ollama API: http://$BIND_ADDR:11434
- LiteLLM API: http://$BIND_ADDR:4000
- SearXNG: http://$BIND_ADDR:8088
- n8n: http://$BIND_ADDR:5678
- Flowise: http://$BIND_ADDR:3001
- Qdrant dashboard: http://$BIND_ADDR:6333/dashboard

All ports are bound to \`$BIND_ADDR\`.

## Secrets

\`\`\`bash
cat "$ENV_FILE"
\`\`\`

## Status

\`\`\`bash
$STACK_DIR/bin/status.sh
\`\`\`

## Start / stop

\`\`\`bash
$STACK_DIR/bin/start.sh
$STACK_DIR/bin/stop.sh
\`\`\`

## Pull models

Default recommended local models:

- $PRIMARY_MODEL
- llama3:latest
- mistral:latest
- qwen2.5-coder:7b
- nomic-embed-text:latest

\`\`\`bash
$STACK_DIR/bin/pull-models.sh
$STACK_DIR/bin/pull-models.sh llama3:latest mistral:latest
\`\`\`

## Run local multi-agent workflow

\`\`\`bash
$STACK_DIR/bin/agent.sh --save "Create a safe Kali Linux local lab maintenance checklist"
\`\`\`

You can override agent models:

\`\`\`bash
PLANNER_MODEL=llama3:latest \\
BUILDER_MODEL=qwen2.5-coder:7b \\
REVIEWER_MODEL=mistral:latest \\
$STACK_DIR/bin/agent.sh --save "Review my Docker Compose config"
\`\`\`

## MCP

Main config:

\`\`\`bash
cat "$STACK_DIR/mcp/mcp.local.json"
\`\`\`

Safe local MCP server:

\`\`\`bash
$STACK_DIR/mcp/.venv/bin/python "$STACK_DIR/mcp/safe_local_mcp.py"
\`\`\`

## HexStrike

If installed:

\`\`\`bash
$STACK_DIR/bin/start-hexstrike-local.sh
$STACK_DIR/bin/stop-hexstrike-local.sh
\`\`\`

Expected local endpoint:

\`\`\`
http://127.0.0.1:8888
\`\`\`

## Backups

\`\`\`bash
$STACK_DIR/bin/backup-volumes.sh
\`\`\`
EOF
}

final_summary() {
  log "Install complete"
  echo
  "$STACK_DIR/bin/status.sh" || true
  echo
  echo "Stack directory: $STACK_DIR"
  echo "README:          $STACK_DIR/README.md"
  echo "MCP config:      $STACK_DIR/mcp/mcp.local.json"
  echo
  echo "Open WebUI:      http://$BIND_ADDR:3000"
  echo
  echo "Try:"
  echo "  $STACK_DIR/bin/agent.sh --save \"Create a safe local Linux hardening checklist\""
}

main() {
  resource_check
  install_base_packages
  install_kali_helpers
  write_litellm_config
  write_searxng_config
  write_compose
  write_local_agents
  write_safe_mcp_server
  install_hexstrike
  write_mcp_config
  write_management_scripts
  write_readme
  start_stack
  pull_models
  final_summary
}

main "$@"
