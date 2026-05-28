# Security model

This project is local-first and scope-gated.

## Defaults

- Services bind to `127.0.0.1` unless you override `--bind`.
- Secrets are generated locally and stored in `~/kaliarc-ai-lab/.env`.
- Open WebUI uses authentication.
- Tool wrappers store reports under `~/kaliarc-ai-lab/reports`.
- Target-specific wrappers check `scope/allowed-targets.txt`.

## HexStrike split

HexStrike is optional and separate from the general-purpose agents. The recommended architecture is:

- General, code, sysadmin, and KaliGPT-style work: local Ollama agents.
- Authorised security-tool orchestration: HexStrike local MCP server.
- Exploitation/post-exploitation actions: manual and auditable.
