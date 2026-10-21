# Prompt delivery after a lost reply

Users do not resend a prompt whose execution reply was lost. The composer reconciles its submission identity and restores a draft only after confirmed non-delivery.

## Sub-features

- `prompt-lost-reply` reconciles execution without a second submission.
- `prompt-before-dispatch` restores an undelivered draft with zero executions.
- `prompt-old-host` preserves the draft and reports unsupported receipt support before dispatch.

## How to get to it (user POV)

Open the composer with Edit > Write Prompt or the default Command-I binding. Select a live terminal and send with Command-Return. Delivery status appears above the composer if the connection loses the execution reply.

## Driving it with dev.sh

Preconditions: the native [composer journey](composer.md), a live owned shell, and guest-local scratch easld. Use unique receipt markers for every attempt. For integrated omp receipts, use [the isolated provider](../omp-provider.md). Qualify shell and integrated delivery separately.

1. Inspect `relay_probe.py` and `ssh-probe` under `/home/tim/agents/projects/easl/state/lanes/easl-prompt-once-1/`. Copy and adapt them inside the recorded guest scratch, never in place. The wrapper must intercept only this scratch host socket and delegate other SSH calls to `$G/ssh`. The retained `proof.py` contains historical failure assertions and direct API sends. Do not use it as native acceptance.
2. Use `$G/faults` as the probe control directory; the retained `ssh-probe` hardcodes that path. Keep its per-connection logs across attempts. Arm `arm.json` with the actual target ID, exact composer text, and `action: cut`. Create `hold-query` to delay each reconciliation request by five seconds. Start the viewer with the probe wrapper, refresh native identity, and run Doctor.
3. Type a shell command into **Prompt** that appends one unique marker to a receipt file. Capture the unsent draft and target. Send through native Command-Return. Require the probe to record a successful host reply before dropping it. The retained probe logs only `ok` and `error`; adapt the scratch copy to retain the successful result too.
4. Capture **Delivery unknown, checking…** during reconnect and the five-second query delay. Remove this attempt's `hold-query` after capture to avoid delaying future queries. Already delayed queries still wait their full five seconds. Require reconciliation, a cleared submitted draft, and exactly one executed marker. Retain host outcome, shell readback, probe transcript, and settled native pixels.
5. Repeat with `action: cut-before`. Require zero executed markers and confirmed restoration of text and mentions. A retry after restoration is a new explicit user send, not an automatic resend.
6. Repeat against guest-local v0.3.0 easld. Its missing `agent.prompt_epoch` must produce a clear update notice and preserve the draft and mentions. Require zero `agent.prompt` dispatches and no shell receipt. Record this as unsupported composer delivery, not a successful prompt send. Judge release acceptability against the release brief.

## Gotchas

- `Sources/CanvasCore/BoardMirror.swift` preflights receipt support before remote delivery.
- `Sources/CanvasCore/RemoteReplayQueue.swift` reconciles the original parameters with `reconcile: true`.
- `Sources/CanvasCore/PromptSubmissionRegistry.swift` and `easld/internal/router/prompt_receipts.go` retain outcomes.
- `Sources/CanvasApp/ComposerController.swift` separates unknown submissions from editable drafts.
- There is no legacy resend fallback on an old host. A missing method must not cause duplicate execution.
- The retained probe cannot hold reconciliation indefinitely. Transport failure keeps the **checking…** label; a host `unknown` outcome produces **Not safe to resend**. Those need separate fault fixtures before claiming either persistent-state path.
- Preserve intermediate failure captures. A final cleared composer alone cannot prove exactly-once delivery.
- Stop only recorded owned probe processes. Export receipts before removing scratch.
