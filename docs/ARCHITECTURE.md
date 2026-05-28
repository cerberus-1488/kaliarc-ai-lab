# Architecture

KaliArc AI Lab is designed as a local-first AI workspace.

```text
User
 ├─ Open WebUI
 ├─ Local CLI agents
 ├─ AI Lab desktop menu
 └─ Scoped Kali tool wrappers
        │
        ├─ Ollama local models
        ├─ LiteLLM OpenAI-compatible proxy
        ├─ Qdrant vector store
        ├─ SearXNG local search
        ├─ n8n workflow automation
        ├─ Flowise visual agents
        ├─ Safe local MCP server
        └─ Optional HexStrike MCP server
```

The core installer creates the Docker services. The extras script adds local agent profiles, Kali tool wrappers, scope management, and menu entries.
