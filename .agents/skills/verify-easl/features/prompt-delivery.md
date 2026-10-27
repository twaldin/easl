# Prompt delivery after a lost reply

On receipt-capable hosts, a lost reply does not trigger resubmission. The composer reconciles its submission identity and restores the submitted draft only after confirmed non-delivery. Legacy hosts cannot provide that guarantee.

## Sub-features

- `prompt-lost-reply` reconciles execution without a second submission.
- `prompt-before-dispatch` restores an undelivered draft with zero executions.
- `prompt-old-host` sends through legacy `agent.prompt` without receipt reconciliation or a blocking update notice.

## How to get to it (user POV)

Open the composer with Edit > Write Prompt or the default Command-I binding. Select a live terminal and send with Command-Return. Delivery status appears above the composer if the connection loses the execution reply.

## Driving it with dev.sh

Preconditions: the native [composer journey](composer.md), a live owned shell, and guest-local scratch easld. Use unique receipt markers for every attempt. For integrated omp receipts, use [the isolated provider](../omp-provider.md). Qualify shell and integrated delivery separately.

1. Inspect `relay_probe.py` and `ssh-probe` under `/home/tim/agents/projects/easl/state/lanes/easl-prompt-once-1/`. Copy and adapt them inside the recorded guest scratch, never in place. The wrapper must intercept only this scratch host socket and delegate other SSH calls to `$G/ssh`. The retained `proof.py` contains historical failure assertions and direct API sends. Do not use it as native acceptance.
2. Use `$G/faults` as the probe control directory; the retained `ssh-probe` hardcodes that path. Keep its per-connection logs across attempts. Arm `arm.json` with the actual target ID, exact composer text, and `action: cut`. Create `hold-query` to delay each reconciliation request by five seconds. Start the viewer with the probe wrapper, refresh native identity, and run Doctor.
3. Type a shell command into **Prompt** that appends one unique marker to a receipt file. Capture the unsent draft and target. Send through native Command-Return. Require the probe to record a successful host reply before dropping it. The retained probe logs only `ok` and `error`; adapt the scratch copy to retain the successful result too.
4. Capture **Delivery unknown, checking…** during reconnect and the five-second query delay. Remove this attempt's `hold-query` after capture to avoid delaying future queries. Already delayed queries still wait their full five seconds. Require reconciliation, a cleared submitted draft, and exactly one executed marker. Retain host outcome, shell readback, probe transcript, and settled native pixels.
5. Repeat with `action: cut-before`. Require zero executed markers and confirmed restoration of text and mentions. A retry after restoration is a new explicit user send, not an automatic resend.
6. Repeat against guest-local v0.3.0 easld. Its missing `agent.prompt_epoch` selects legacy delivery. Require one `agent.prompt` dispatch, a cleared draft, and exactly one shell receipt after native Command-Return. For a separate dropped-reply attempt, require no automatic replay or reconciliation. The draft returns even if execution already happened, as in v0.3.0. A manual retry can duplicate execution.

## Gotchas

- `Sources/CanvasCore/BoardMirror.swift` preflights receipt support before remote delivery.
- `Sources/CanvasCore/RemoteReplayQueue.swift` reconciles the original parameters with `reconcile: true`.
- `Sources/CanvasCore/PromptSubmissionRegistry.swift` and `easld/internal/router/prompt_receipts.go` retain outcomes.
- `Sources/CanvasApp/ComposerController.swift` separates unknown submissions from editable drafts.
- Old hosts receive the legacy request once. A missing epoch method must not trigger automatic resubmission. Lost-reply safety requires a host with submission receipts.
- The retained probe cannot hold reconciliation indefinitely. Transport failure keeps the **checking…** label; a host `unknown` outcome produces **Not safe to resend**. Those need separate fault fixtures before claiming either persistent-state path.
- Preserve intermediate failure captures. A final cleared composer alone cannot prove exactly-once delivery.
- Stop only recorded owned probe processes. Export receipts before removing scratch.
