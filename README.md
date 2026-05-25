# LLM API Connectivity Smoke Test

Minimal cross-platform scripts to verify whether your current network can reach LLM API endpoints.

## What this repo tests

- AICodeMirror OpenAI-compatible `chat/completions` (default model: `gpt-5.3-codex`)
- MiniMax OpenAI-compatible endpoint (`/v1/models`)

The scripts send a lightweight authenticated request and report `PASS`, `FAIL`, or `SKIP`.
For provider-side rejections (e.g. invalid key / model-plan mismatch), scripts report `WARN` while still treating network path as reachable.

## Requirements

- Linux/macOS: `bash` + `curl`
- Windows: PowerShell (built-in `Invoke-RestMethod`)

No extra SDK/library installation is required.

## Setup

1. Copy env template:

```bash
cp .env.example .env
```

On Windows PowerShell:

```powershell
Copy-Item .env.example .env
```

2. Edit `.env` and fill API keys.
3. Set `AICM_BASE_URL` from your AICodeMirror dashboard docs page.
4. Optional: set `AICM_MODEL` (default: `gpt-5.3-codex`).

## Run on Linux/macOS (bash)

```bash
bash ./scripts/test_llm_api.sh
```

Optional custom env file:

```bash
bash ./scripts/test_llm_api.sh /path/to/your.env
```

## Run on Windows PowerShell

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\test_llm_api.ps1
```

Optional custom env file:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\test_llm_api.ps1 -EnvFile .\my.env
```

## Exit codes

- `0`: network path is reachable (even if API returns `WARN`)
- `1`: at least one endpoint is not reachable from network/runtime perspective
- `2`: missing required runtime command (bash script only)

## Notes

- If a provider key/base URL is empty, that provider is reported as `SKIP`.
- MiniMax Token Plan in mainland China commonly uses `https://api.minimaxi.com`.
- If you see `Settlement blocked` / `SETTLEMENT_UNKNOWN_MODEL`, network is usually fine and the issue is model billing mapping on provider side.
