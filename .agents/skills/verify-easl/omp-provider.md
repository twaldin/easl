# Verify integrated composer delivery without provider credentials

Use real omp and the repo's easl extension. Replace only the external model-provider HTTP boundary with a guest-local OpenAI-compatible server. This checks prompt and mention delivery, not model quality or authenticated provider behavior. Never copy a user's omp profile, credentials, or session history into the guest.

## Start the isolated provider

The retained finite fixture source is `/home/tim/agents/projects/easl/state/lanes/easl-prompt-once-1/model_stub.py`. Inspect it, copy it through home into your recorded `G`, and run it in a separate guest login-shell job:

```sh
python3 "$G/model_stub.py" "$G"
```

Record its PID from `$G/stub.pid`, wait for `STUB_READY`, and read the chosen loopback port from `$G/stub-port`. It writes only synthetic request receipts under `G`. It returns a fixed streaming assistant reply. Do not bind it to a public interface.

Generate fresh profile and session directories from the actual stub port:

```sh
python3 - "$G" <<'PY'
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
profile = root / "omp-profile"
profile.mkdir()
(root / "omp-sessions").mkdir()
port = int((root / "stub-port").read_text())
models = {"providers": {"guest-stub": {
    "api": "openai-completions", "baseUrl": f"http://127.0.0.1:{port}/v1",
    "apiKey": "dummy-guest-key",
    "models": [{"id": "composer-fixed", "name": "Composer fixed reply",
                "reasoning": False, "input": ["text"],
                "contextWindow": 128000, "maxTokens": 1024}],
}}}
(profile / "models.yml").write_text(json.dumps(models))
(root / "omp-config.yml").write_text(json.dumps({
    "startup": {"setupWizard": False, "checkUpdate": False, "showSplash": False},
    "autoResume": False,
}))
PY
```

`dummy-guest-key` is a literal test value, never a real credential.

Create a terminal through `object.create` with `type: terminal`, `props.cwd` set to the scratch board root, and `props.command` containing these separate argv elements, expanding `G` and `R` to their actual absolute paths:

```sh
/usr/bin/env PI_CODING_AGENT_DIR="$G/omp-profile" \
  bunx --bun @oh-my-pi/pi-coding-agent@18.12.3 \
  --model guest-stub/composer-fixed --thinking off --no-tools --no-lsp \
  --no-title --no-rules --no-skills --no-extensions \
  -e "$R/extensions/omp/easl.ts" --config "$G/omp-config.yml" \
  --session-dir "$G/omp-sessions"
```

Record the resolved omp version. The retained proof used 18.12.3; a newer version needs the same readiness checks, not an assumed compatible setup. Require `agent.list` to report kind `omp`, a live native PID/session, the expected model, and a ready lifecycle. Capture the actual terminal. If a setup wizard is visible, the precondition failed. Do not type the test prompt into its search box and call that delivery.

## Check the real receipt

Use the native [composer journey](features/composer.md), not a direct `agent.prompt` call. Send a unique marker with one Hyper-clicked note. Retain the unsent native draft, its selected target, the sent result, and the visible fixed reply.

Read the **new fixture session** JSONL under `$G/omp-sessions`. Require exactly one user message containing the marker. Before the next user message, require one `custom_message` with `customType: canvas.mentions`, `attribution: user`, `display: false`, and the actual resolved note text. Save the relevant synthetic session entries alongside captures. Provider request counts alone can include retries and do not establish exactly-once session delivery.

For reply-loss recovery, follow [the native prompt-delivery journey](features/prompt-delivery.md), which describes the retained relay fixtures and their timing limits. Use the integrated session receipts above when qualifying omp. A shell execution count does not prove an integrated agent receipt.

Stop the recorded omp through the owned terminal session, then terminate only the recorded provider and probe PIDs. Export synthetic receipts, then remove their exact scratch paths during normal guest cleanup. No external provider traffic or real credentials are required.
