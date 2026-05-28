# Tool integrations

The repository adds wrappers and launchers for common Kali tools.

## Scope-gated wrappers

These require entries in `~/kaliarc-ai-lab/scope/allowed-targets.txt`:

- `nmap-safe.sh`
- `osint-domain.sh`

Add scope:

```bash
~/kaliarc-ai-lab/bin/scope-add.sh 192.168.56.0/24
~/kaliarc-ai-lab/bin/scope-add.sh example.test
```

## Manual launchers

These open tools for manual, auditable use:

- `spiderfoot-local.sh`
- `burp-suite.sh`
- `metasploit-workspace.sh`
- `wireshark-launch.sh`
- `tshark-capture.sh`
- `zap-local.sh`

## AI reporting

Convert tool output into notes:

```bash
~/kaliarc-ai-lab/bin/report-file.sh ~/kaliarc-ai-lab/reports/output.txt
```
