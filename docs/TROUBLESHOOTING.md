# Troubleshooting

## Docker services are not running

```bash
~/kaliarc-ai-lab/bin/status.sh
~/kaliarc-ai-lab/bin/start.sh
```

## Ollama model pull failed

```bash
~/kaliarc-ai-lab/bin/pull-models.sh llama3:latest mistral:latest
```

## Open WebUI does not open

Check:

```bash
sudo docker ps --filter name=kali-ai
curl http://127.0.0.1:3000
```

## Menu entry is missing

Run the extras script again:

```bash
./scripts/post-install-extras.sh --with-hexstrike
```

Then log out/in or restart the panel if your desktop menu cache does not refresh.

## Tool says target is out of scope

Add an authorised target:

```bash
~/kaliarc-ai-lab/bin/scope-add.sh 192.168.56.0/24
```
