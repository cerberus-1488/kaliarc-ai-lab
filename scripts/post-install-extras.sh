#!/usr/bin/env bash
set -Eeuo pipefail

STACK_DIR="${STACK_DIR:-$HOME/kaliarc-ai-lab}"
BIND_ADDR="${BIND_ADDR:-127.0.0.1}"
INSTALL_TOOLS=1
INSTALL_MENU=1
WITH_HEXSTRIKE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bind)
      BIND_ADDR="${2:?Missing bind address after --bind}"
      shift 2
      ;;
    --with-hexstrike|--start-hexstrike)
      WITH_HEXSTRIKE=1
      shift
      ;;
    --no-tool-install|--no-kali-tools)
      INSTALL_TOOLS=0
      shift
      ;;
    --no-menu)
      INSTALL_MENU=0
      shift
      ;;
    --help|-h)
      cat <<EOF
Usage:
  scripts/post-install-extras.sh [options]

Options:
  --bind ADDR            Local bind address used in menu URLs. Default: 127.0.0.1
  --with-hexstrike       Add HexStrike launcher if the base installer installed it
  --no-tool-install      Do not attempt to install extra Kali tool packages
  --no-menu              Do not create XDG/Kali menu entries
EOF
      exit 0
      ;;
    *)
      # Ignore options meant for install.sh, such as --full, --gpu, --model.
      shift
      ;;
  esac
done

log()  { printf "\033[1;32m[+]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[!]\033[0m %s\n" "$*" >&2; }

[[ -d "$STACK_DIR" ]] || {
  warn "$STACK_DIR does not exist yet. Run ./install.sh first or use ./setup.sh."
  exit 1
}

mkdir -p "$STACK_DIR"/{agents,bin,scope,reports,outputs,logs}

install_optional_tools() {
  [[ "$INSTALL_TOOLS" -eq 1 ]] || return 0
  if ! command -v apt-get >/dev/null 2>&1; then
    warn "apt-get not found; skipping optional Kali tool install."
    return 0
  fi

  log "Installing optional Kali helper/integration packages where available"
  sudo -v
  sudo apt-get update || true

  local packages=(
    nmap
    whatweb
    nikto
    gobuster
    dirb
    feroxbuster
    ffuf
    wafw00f
    sslscan
    dnsutils
    whois
    traceroute
    spiderfoot
    burpsuite
    metasploit-framework
    wireshark
    tshark
    zaproxy
  )

  for pkg in "${packages[@]}"; do
    sudo apt-get install -y "$pkg" >/dev/null 2>&1 || warn "Optional package unavailable or not installed: $pkg"
  done
}

write_profile_agents() {
  log "Writing general/KaliGPT/code/sysadmin/report agent launchers"

  cat > "$STACK_DIR/agents/profile_agent.py" <<'PY'
#!/usr/bin/env python3
import argparse
import datetime as dt
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

LAB_DIR = Path(__file__).resolve().parents[1]
LOG_DIR = LAB_DIR / "logs"
DEFAULT_MODEL = os.environ.get("MODEL", os.environ.get("PRIMARY_MODEL", "gemma3:latest"))
OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434/api/chat")

PROFILES = {
    "general": (
        "You are a private, local, general-purpose AI assistant. Help with planning, writing, research notes, "
        "summaries, troubleshooting, study plans, productivity, automation ideas, and day-to-day Linux usage. "
        "Keep answers practical and concise."
    ),
    "code": (
        "You are a senior local coding assistant. Produce clean, tested, maintainable code. Explain commands briefly, "
        "include validation and rollback where relevant, and avoid leaking secrets."
    ),
    "sysadmin": (
        "You are a Kali/Linux sysadmin assistant. Help with packages, services, logs, networking, Docker, backups, "
        "hardening, and troubleshooting. Prefer safe diagnostic commands before making changes."
    ),
    "kali-gpt": (
        "You are a local KaliGPT-style assistant for Kali Linux learning, command explanations, lab setup, "
        "defensive security, authorised testing workflows, reporting, and troubleshooting. Keep scope local or authorised."
    ),
    "report": (
        "You are a technical reporting assistant. Convert raw command output into concise findings, evidence, "
        "risk notes, remediation steps, and verification checks. Do not invent findings."
    ),
}

def chat(model: str, system: str, prompt: str) -> str:
    payload = {
        "model": model,
        "stream": False,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": prompt},
        ],
    }
    req = urllib.request.Request(
        OLLAMA_URL,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=900) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except urllib.error.URLError as exc:
        raise SystemExit(f"Could not reach Ollama at {OLLAMA_URL}: {exc}")
    return data.get("message", {}).get("content", "")

def main() -> None:
    parser = argparse.ArgumentParser(description="Run a local Ollama-backed agent profile.")
    parser.add_argument("prompt", nargs="*", help="Prompt text")
    parser.add_argument("--profile", choices=sorted(PROFILES), default=os.environ.get("AGENT_PROFILE", "general"))
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--file", action="append", default=[], help="Append a text file to the prompt")
    parser.add_argument("--save", action="store_true", help="Save output under logs/")
    args = parser.parse_args()

    prompt = " ".join(args.prompt).strip()
    file_chunks = []
    for file_name in args.file:
        path = Path(file_name).expanduser()
        if not path.exists():
            raise SystemExit(f"File not found: {path}")
        file_chunks.append(f"\n\n--- FILE: {path} ---\n{path.read_text(errors='replace')[:120000]}")
    prompt = (prompt + "".join(file_chunks)).strip()

    if not prompt:
        prompt = input("Prompt: ").strip()

    if not prompt:
        raise SystemExit("No prompt supplied.")

    output = chat(args.model, PROFILES[args.profile], prompt)
    print(output)

    if args.save:
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        out_file = LOG_DIR / f"{args.profile}-{stamp}.md"
        out_file.write_text(
            f"# {args.profile} agent output\n\n"
            f"- Model: `{args.model}`\n"
            f"- Timestamp: `{stamp}`\n\n"
            f"## Prompt\n\n{prompt}\n\n## Output\n\n{output}\n",
            encoding="utf-8",
        )
        print(f"\n[+] Saved: {out_file}")

if __name__ == "__main__":
    main()
PY
  chmod +x "$STACK_DIR/agents/profile_agent.py"

  for entry in \
    "general:general-agent.sh" \
    "code:code-agent.sh" \
    "sysadmin:sysadmin-agent.sh" \
    "kali-gpt:kali-gpt-local.sh" \
    "report:report-agent.sh"
  do
    local profile="${entry%%:*}"
    local script="${entry##*:}"
    cat > "$STACK_DIR/bin/$script" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="\$(cd "\$SCRIPT_DIR/.." && pwd)"
export AGENT_PROFILE="$profile"
exec python3 "\$LAB_DIR/agents/profile_agent.py" --save "\$@"
EOF
    chmod +x "$STACK_DIR/bin/$script"
  done

  cat > "$STACK_DIR/bin/agent-menu.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "KaliArc AI Lab - Agent Menu"
echo
select choice in \
  "General Agent" \
  "Code Agent" \
  "Sysadmin Agent" \
  "KaliGPT Local" \
  "Multi-Agent Workflow" \
  "Quit"
do
  case "$REPLY" in
    1) read -rp "Prompt: " p; "$SCRIPT_DIR/general-agent.sh" "$p"; break ;;
    2) read -rp "Prompt: " p; "$SCRIPT_DIR/code-agent.sh" "$p"; break ;;
    3) read -rp "Prompt: " p; "$SCRIPT_DIR/sysadmin-agent.sh" "$p"; break ;;
    4) read -rp "Prompt: " p; "$SCRIPT_DIR/kali-gpt-local.sh" "$p"; break ;;
    5) read -rp "Prompt: " p; "$SCRIPT_DIR/agent.sh" --save "$p"; break ;;
    6) exit 0 ;;
    *) echo "Invalid selection" ;;
  esac
done
EOF
  chmod +x "$STACK_DIR/bin/agent-menu.sh"
}

write_tool_integrations() {
  log "Writing scoped Kali tool integrations"

  touch "$STACK_DIR/scope/allowed-targets.txt"
  cat > "$STACK_DIR/scope/README.md" <<'EOF'
# Scope file

Add only targets you own or are authorised to test.

Supported entries:

- CIDR: `192.168.56.0/24`
- IP: `10.10.10.5`
- Domain: `example.test`

Examples:

```bash
~/kaliarc-ai-lab/bin/scope-add.sh 192.168.56.0/24
~/kaliarc-ai-lab/bin/scope-add.sh example.test
~/kaliarc-ai-lab/bin/scope-list.sh
```
EOF

  cat > "$STACK_DIR/bin/scope-add.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCOPE_FILE="$LAB_DIR/scope/allowed-targets.txt"
[[ $# -ge 1 ]] || { echo "Usage: $0 TARGET_OR_CIDR_OR_DOMAIN"; exit 1; }
mkdir -p "$(dirname "$SCOPE_FILE")"
for target in "$@"; do
  grep -Fxq "$target" "$SCOPE_FILE" 2>/dev/null || echo "$target" >> "$SCOPE_FILE"
  echo "[+] Added to scope: $target"
done
EOF

  cat > "$STACK_DIR/bin/scope-list.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCOPE_FILE="$LAB_DIR/scope/allowed-targets.txt"
echo "Scope file: $SCOPE_FILE"
echo
grep -vE '^\s*(#|$)' "$SCOPE_FILE" 2>/dev/null || true
EOF

  cat > "$STACK_DIR/bin/scope-remove.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCOPE_FILE="$LAB_DIR/scope/allowed-targets.txt"
[[ $# -eq 1 ]] || { echo "Usage: $0 TARGET_OR_CIDR_OR_DOMAIN"; exit 1; }
tmp="$(mktemp)"
grep -Fxv "$1" "$SCOPE_FILE" > "$tmp" || true
mv "$tmp" "$SCOPE_FILE"
echo "[+] Removed from scope if present: $1"
EOF

  cat > "$STACK_DIR/bin/scope-check.py" <<'PY'
#!/usr/bin/env python3
import ipaddress
import sys
from pathlib import Path
from urllib.parse import urlparse

LAB_DIR = Path(__file__).resolve().parents[1]
SCOPE_FILE = LAB_DIR / "scope" / "allowed-targets.txt"

def normalise_target(raw: str) -> str:
    raw = raw.strip()
    parsed = urlparse(raw if "://" in raw else f"//{raw}")
    host = parsed.hostname or raw
    return host.strip("[]").lower().rstrip(".")

def load_scope():
    if not SCOPE_FILE.exists():
        return []
    items = []
    for line in SCOPE_FILE.read_text(errors="replace").splitlines():
        line = line.strip().lower().rstrip(".")
        if not line or line.startswith("#"):
            continue
        items.append(line)
    return items

def in_scope(target: str, scope_items) -> bool:
    host = normalise_target(target)
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        ip = None

    for item in scope_items:
        if item == host:
            return True

        if ip is not None:
            try:
                if ip in ipaddress.ip_network(item, strict=False):
                    return True
            except ValueError:
                pass

        if ip is None and (host == item or host.endswith("." + item)):
            return True

    return False

def main():
    if len(sys.argv) != 2:
        print("Usage: scope-check.py TARGET", file=sys.stderr)
        sys.exit(2)
    scope = load_scope()
    if not scope:
        print(f"[x] No allowed targets configured. Add scope with: {LAB_DIR}/bin/scope-add.sh TARGET", file=sys.stderr)
        sys.exit(1)
    target = sys.argv[1]
    if in_scope(target, scope):
        print(f"[+] In scope: {target}")
        return
    print(f"[x] Target is not in scope: {target}", file=sys.stderr)
    print(f"    Add it only if authorised: {LAB_DIR}/bin/scope-add.sh {normalise_target(target)}", file=sys.stderr)
    sys.exit(1)

if __name__ == "__main__":
    main()
PY

  cat > "$STACK_DIR/bin/nmap-safe.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="${1:-}"
[[ -n "$TARGET" ]] || { echo "Usage: $0 TARGET [extra nmap args]"; exit 1; }
shift || true
"$SCRIPT_DIR/scope-check.py" "$TARGET"
command -v nmap >/dev/null 2>&1 || { echo "[x] nmap is not installed"; exit 1; }
STAMP="$(date +%Y%m%d-%H%M%S)"
OUTBASE="$LAB_DIR/reports/nmap-$STAMP"
echo "[+] Running scoped Nmap scan. Output base: $OUTBASE"
nmap -sV -oA "$OUTBASE" "$@" "$TARGET"
echo "[+] Analyse with: $SCRIPT_DIR/report-file.sh ${OUTBASE}.nmap"
EOF

  cat > "$STACK_DIR/bin/spiderfoot-local.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
HOST="${SPIDERFOOT_HOST:-127.0.0.1}"
PORT="${SPIDERFOOT_PORT:-5001}"
echo "[+] Starting SpiderFoot locally at http://$HOST:$PORT"
if command -v spiderfoot >/dev/null 2>&1; then
  exec spiderfoot -l "$HOST:$PORT"
elif [[ -f /usr/share/spiderfoot/sf.py ]]; then
  cd /usr/share/spiderfoot
  exec python3 sf.py -l "$HOST:$PORT"
else
  echo "[x] SpiderFoot not found. Install it with: sudo apt install spiderfoot"
  exit 1
fi
EOF

  cat > "$STACK_DIR/bin/burp-suite.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if command -v burpsuite >/dev/null 2>&1; then
  exec burpsuite "$@"
fi
echo "[x] Burp Suite launcher not found. Try: sudo apt install burpsuite"
exit 1
EOF

  cat > "$STACK_DIR/bin/metasploit-workspace.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
WORKSPACE="${1:-kali-ai-lab}"
if ! command -v msfconsole >/dev/null 2>&1; then
  echo "[x] Metasploit not found. Try: sudo apt install metasploit-framework"
  exit 1
fi
echo "[+] Opening Metasploit workspace: $WORKSPACE"
echo "[+] This launcher opens msfconsole only; actions remain manual."
exec msfconsole -q -x "workspace -a $WORKSPACE; workspace $WORKSPACE"
EOF

  cat > "$STACK_DIR/bin/wireshark-launch.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if command -v wireshark >/dev/null 2>&1; then
  exec wireshark "$@"
fi
echo "[x] Wireshark not found. Try: sudo apt install wireshark"
exit 1
EOF

  cat > "$STACK_DIR/bin/tshark-capture.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
IFACE="${1:-}"
DURATION="${2:-60}"
[[ -n "$IFACE" ]] || { echo "Usage: $0 INTERFACE [duration_seconds]"; exit 1; }
command -v tshark >/dev/null 2>&1 || { echo "[x] tshark not installed. Try: sudo apt install tshark"; exit 1; }
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$LAB_DIR/reports/tshark-$IFACE-$STAMP.pcapng"
echo "[+] Capturing $DURATION seconds on $IFACE to $OUT"
sudo timeout "$DURATION" tshark -i "$IFACE" -w "$OUT"
echo "[+] Capture saved: $OUT"
EOF

  cat > "$STACK_DIR/bin/zap-local.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
HOST="${ZAP_HOST:-127.0.0.1}"
PORT="${ZAP_PORT:-8081}"
if command -v zaproxy >/dev/null 2>&1; then
  echo "[+] Starting OWASP ZAP locally on $HOST:$PORT"
  exec zaproxy -host "$HOST" -port "$PORT" "$@"
elif command -v zap.sh >/dev/null 2>&1; then
  exec zap.sh -host "$HOST" -port "$PORT" "$@"
fi
echo "[x] OWASP ZAP not found. Try: sudo apt install zaproxy"
exit 1
EOF

  cat > "$STACK_DIR/bin/osint-domain.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="${1:-}"
[[ -n "$TARGET" ]] || { echo "Usage: $0 DOMAIN_OR_URL"; exit 1; }
"$SCRIPT_DIR/scope-check.py" "$TARGET"
STAMP="$(date +%Y%m%d-%H%M%S)"
SAFE_TARGET="$(echo "$TARGET" | tr -c 'A-Za-z0-9._-' '_')"
OUT="$LAB_DIR/reports/osint-$SAFE_TARGET-$STAMP.txt"
{
  echo "# OSINT snapshot for $TARGET"
  echo
  echo "## whois"
  command -v whois >/dev/null 2>&1 && whois "$TARGET" 2>/dev/null || true
  echo
  echo "## DNS A/AAAA/MX/TXT/NS"
  if command -v dig >/dev/null 2>&1; then
    for t in A AAAA MX TXT NS; do
      echo "### $t"
      dig +short "$TARGET" "$t" 2>/dev/null || true
    done
  fi
  echo
  echo "## whatweb"
  command -v whatweb >/dev/null 2>&1 && whatweb "$TARGET" || true
} | tee "$OUT"
echo "[+] Saved: $OUT"
echo "[+] Analyse with: $SCRIPT_DIR/report-file.sh $OUT"
EOF

  cat > "$STACK_DIR/bin/report-file.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILE="${1:-}"
[[ -f "$FILE" ]] || { echo "Usage: $0 REPORT_OR_OUTPUT_FILE"; exit 1; }
shift || true
PROMPT="${*:-Summarise this output into findings, evidence, remediation, and next checks.}"
exec "$SCRIPT_DIR/report-agent.sh" --file "$FILE" "$PROMPT"
EOF

  cat > "$STACK_DIR/bin/tool-menu.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "KaliArc AI Lab - Tool Menu"
echo
select choice in \
  "List scope" \
  "Add scope target" \
  "Nmap safe scan" \
  "SpiderFoot local UI" \
  "Burp Suite" \
  "Metasploit workspace" \
  "Wireshark" \
  "TShark capture" \
  "OWASP ZAP local" \
  "OSINT domain snapshot" \
  "AI report a file" \
  "Quit"
do
  case "$REPLY" in
    1) "$SCRIPT_DIR/scope-list.sh";;
    2) read -rp "Target/CIDR/domain: " t; "$SCRIPT_DIR/scope-add.sh" "$t";;
    3) read -rp "Target: " t; "$SCRIPT_DIR/nmap-safe.sh" "$t";;
    4) "$SCRIPT_DIR/spiderfoot-local.sh";;
    5) "$SCRIPT_DIR/burp-suite.sh";;
    6) read -rp "Workspace [kali-ai-lab]: " w; "$SCRIPT_DIR/metasploit-workspace.sh" "${w:-kali-ai-lab}";;
    7) "$SCRIPT_DIR/wireshark-launch.sh";;
    8) read -rp "Interface: " i; read -rp "Duration seconds [60]: " d; "$SCRIPT_DIR/tshark-capture.sh" "$i" "${d:-60}";;
    9) "$SCRIPT_DIR/zap-local.sh";;
    10) read -rp "Domain/URL: " d; "$SCRIPT_DIR/osint-domain.sh" "$d";;
    11) read -rp "File path: " f; "$SCRIPT_DIR/report-file.sh" "$f";;
    12) exit 0;;
    *) echo "Invalid selection";;
  esac
  echo
done
EOF

  chmod +x "$STACK_DIR/bin/"*.sh "$STACK_DIR/bin/scope-check.py"
}

write_menu_launchers() {
  [[ "$INSTALL_MENU" -eq 1 ]] || return 0
  log "Writing Kali/XDG AI Lab menu launchers"

  local app_dir="$HOME/.local/share/applications"
  local dir_dir="$HOME/.local/share/desktop-directories"
  local menu_dir="$HOME/.config/menus/applications-merged"
  mkdir -p "$app_dir" "$dir_dir" "$menu_dir"

  cat > "$dir_dir/ai-lab.directory" <<'EOF'
[Desktop Entry]
Type=Directory
Name=AI Lab
Comment=Local AI agents, lab services, and authorised security tooling
Icon=applications-science
EOF

  cat > "$menu_dir/ai-lab.menu" <<'EOF'
<!DOCTYPE Menu PUBLIC "-//freedesktop//DTD Menu 1.0//EN"
 "http://www.freedesktop.org/standards/menu-spec/menu-1.0.dtd">
<Menu>
  <Name>Applications</Name>
  <Menu>
    <Name>AI Lab</Name>
    <Directory>ai-lab.directory</Directory>
    <Include>
      <Category>X-AILab</Category>
    </Include>
  </Menu>
</Menu>
EOF

  make_desktop() {
    local name="$1"
    local comment="$2"
    local exec_cmd="$3"
    local icon="$4"
    local terminal="$5"
    local file="$6"
    cat > "$app_dir/$file" <<EOF
[Desktop Entry]
Type=Application
Name=$name
Comment=$comment
Exec=$exec_cmd
Icon=$icon
Terminal=$terminal
Categories=Utility;Development;Education;Science;ArtificialIntelligence;X-AILab;
StartupNotify=false
EOF
  }

  make_desktop "AI Lab - Open WebUI" "Open local Open WebUI" "xdg-open http://$BIND_ADDR:3000" "web-browser" "false" "ai-lab-open-webui.desktop"
  make_desktop "AI Lab - Agent Menu" "Open local AI agent menu" "$STACK_DIR/bin/agent-menu.sh" "utilities-terminal" "true" "ai-lab-agent-menu.desktop"
  make_desktop "AI Lab - Tool Menu" "Open scoped Kali tool integrations" "$STACK_DIR/bin/tool-menu.sh" "applications-system" "true" "ai-lab-tool-menu.desktop"
  make_desktop "AI Lab - Status" "Show AI Lab service status" "$STACK_DIR/bin/status.sh" "dialog-information" "true" "ai-lab-status.desktop"
  make_desktop "AI Lab - Start Services" "Start local AI services" "$STACK_DIR/bin/start.sh" "media-playback-start" "true" "ai-lab-start.desktop"
  make_desktop "AI Lab - Stop Services" "Stop local AI services" "$STACK_DIR/bin/stop.sh" "media-playback-stop" "true" "ai-lab-stop.desktop"
  make_desktop "AI Lab - KaliGPT Local" "Run local KaliGPT-style assistant" "$STACK_DIR/bin/kali-gpt-local.sh" "utilities-terminal" "true" "ai-lab-kali-gpt-local.desktop"
  make_desktop "AI Lab - General Agent" "Run general-purpose local AI agent" "$STACK_DIR/bin/general-agent.sh" "utilities-terminal" "true" "ai-lab-general-agent.desktop"
  make_desktop "AI Lab - Code Agent" "Run local coding agent" "$STACK_DIR/bin/code-agent.sh" "text-x-script" "true" "ai-lab-code-agent.desktop"
  make_desktop "AI Lab - Flowise" "Open local Flowise" "xdg-open http://$BIND_ADDR:3001" "applications-internet" "false" "ai-lab-flowise.desktop"
  make_desktop "AI Lab - n8n" "Open local n8n" "xdg-open http://$BIND_ADDR:5678" "applications-internet" "false" "ai-lab-n8n.desktop"
  make_desktop "AI Lab - SearXNG" "Open local SearXNG" "xdg-open http://$BIND_ADDR:8088" "system-search" "false" "ai-lab-searxng.desktop"
  make_desktop "AI Lab - SpiderFoot" "Launch SpiderFoot local UI" "$STACK_DIR/bin/spiderfoot-local.sh" "applications-internet" "true" "ai-lab-spiderfoot.desktop"
  make_desktop "AI Lab - Burp Suite" "Launch Burp Suite" "$STACK_DIR/bin/burp-suite.sh" "applications-development" "false" "ai-lab-burp-suite.desktop"
  make_desktop "AI Lab - Metasploit Workspace" "Open msfconsole lab workspace" "$STACK_DIR/bin/metasploit-workspace.sh" "utilities-terminal" "true" "ai-lab-metasploit.desktop"
  make_desktop "AI Lab - Wireshark" "Launch Wireshark" "$STACK_DIR/bin/wireshark-launch.sh" "wireshark" "false" "ai-lab-wireshark.desktop"

  if [[ "$WITH_HEXSTRIKE" -eq 1 && -x "$STACK_DIR/bin/start-hexstrike-local.sh" ]]; then
    make_desktop "AI Lab - Start HexStrike Local" "Start local HexStrike API" "$STACK_DIR/bin/start-hexstrike-local.sh" "utilities-terminal" "true" "ai-lab-hexstrike.desktop"
  fi

  cat > "$STACK_DIR/bin/remove-menu.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
rm -f "$app_dir"/ai-lab-*.desktop
rm -f "$dir_dir/ai-lab.directory"
rm -f "$menu_dir/ai-lab.menu"
xdg-desktop-menu forceupdate 2>/dev/null || true
echo "[+] Removed AI Lab menu entries"
EOF
  chmod +x "$STACK_DIR/bin/remove-menu.sh"

  xdg-desktop-menu forceupdate 2>/dev/null || true
}

write_runtime_extras_readme() {
  cat > "$STACK_DIR/EXTRAS.md" <<EOF
# KaliArc AI Lab extras

## Agent launchers

\`\`\`bash
$STACK_DIR/bin/general-agent.sh "Plan my week"
$STACK_DIR/bin/code-agent.sh "Review this Python script" --file ./script.py
$STACK_DIR/bin/sysadmin-agent.sh "Help troubleshoot Docker"
$STACK_DIR/bin/kali-gpt-local.sh "Explain Kali package management"
$STACK_DIR/bin/agent-menu.sh
\`\`\`

## Scoped Kali tool integrations

Add scope before running target-specific tools:

\`\`\`bash
$STACK_DIR/bin/scope-add.sh 192.168.56.0/24
$STACK_DIR/bin/scope-list.sh
$STACK_DIR/bin/nmap-safe.sh 192.168.56.10
$STACK_DIR/bin/osint-domain.sh example.test
$STACK_DIR/bin/report-file.sh "$STACK_DIR/reports/example.txt"
$STACK_DIR/bin/tool-menu.sh
\`\`\`

Launchers:

\`\`\`bash
$STACK_DIR/bin/spiderfoot-local.sh
$STACK_DIR/bin/burp-suite.sh
$STACK_DIR/bin/metasploit-workspace.sh kali-ai-lab
$STACK_DIR/bin/wireshark-launch.sh
$STACK_DIR/bin/zap-local.sh
\`\`\`

## Kali menu

Look for:

\`\`\`
Applications -> AI Lab
\`\`\`

Remove menu entries:

\`\`\`bash
$STACK_DIR/bin/remove-menu.sh
\`\`\`
EOF
}

install_optional_tools
write_profile_agents
write_tool_integrations
write_menu_launchers
write_runtime_extras_readme

log "Extras installed"
echo "Agent menu: $STACK_DIR/bin/agent-menu.sh"
echo "Tool menu:  $STACK_DIR/bin/tool-menu.sh"
echo "Docs:       $STACK_DIR/EXTRAS.md"
