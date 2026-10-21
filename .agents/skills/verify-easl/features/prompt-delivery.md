# Prompt delivery after a lost reply

Users do not resend a prompt whose execution reply was lost. The composer reconciles its submission identity and restores a draft only after confirmed non-delivery.

## Sub-features

- `prompt-lost-reply` reconciles execution without a second submission.
- `prompt-before-dispatch` restores an undelivered draft with zero executions.
- `prompt-unknown` keeps uncertain delivery visible and separate from a new draft.
- `prompt-old-host` preserves the draft and reports unsupported receipt support before dispatch.

## Driving it with dev.sh

Preconditions: the native [composer journey](composer.md), a live owned shell, and guest-local scratch easld. Use unique receipt markers for every attempt. For integrated omp receipts, use [the isolated provider](../omp-provider.md). Qualify shell and integrated delivery separately.

1. Inspect `relay_probe.py` and `ssh-probe` under `/home/tim/agents/projects/easl/state/lanes/easl-prompt-once-1/`. Copy and adapt them inside the recorded guest scratch, never in place. The wrapper must intercept only this scratch host socket and delegate other SSH calls to `$G/ssh`. The retained `proof.py` contains historical failure assertions and direct API sends. Do not use it as native acceptance.
2. Make a fresh probe control directory. Arm its `arm.json` with the actual target ID, exact composer text, and `action: cut`. Create `hold-query` to delay reconciliation. Start the viewer with the probe wrapper, refresh native identity, and run Doctor.
3. Type a shell command into **Prompt** that appends one unique marker to a receipt file. Capture the unsent draft and target. Send through native Command-Return. Require the probe to record a successful host reply before dropping it. The retained probe logs only `ok` and `error`; adapt the scratch copy to retain the successful result too.
4. Capture **Delivery unknown, checking…** with a fresh exact-window receipt. Remove only this attempt's `hold-query`, then require reconciliation, a cleared submitted draft, and exactly one executed marker. Retain host outcome, shell readback, probe transcript, and settled native pixels.
5. Repeat with `action: cut-before`. Require zero executed markers and confirmed restoration of text and mentions. A retry after restoration is a new explicit user send, not an automatic resend.
6. Keep reconciliation unavailable in a separate attempt. Capture persistent unknown delivery, type a different next draft, restore transport, and require reconciliation not to overwrite that draft. Never press Send again to resolve uncertainty.
7. Repeat against guest-local v0.3.0 easld. Its missing `agent.prompt_epoch` must produce a clear update notice and preserve the draft and mentions. Require zero `agent.prompt` dispatches and no shell receipt. Record this as unsupported composer delivery, not a successful prompt send. Judge release acceptability against the release brief.

## Sources and gotchas

- `Sources/CanvasCore/BoardMirror.swift` preflights receipt support before remote delivery.
- `Sources/CanvasCore/RemoteReplayQueue.swift` reconciles the original parameters with `reconcile: true`.
- `Sources/CanvasCore/PromptSubmissionRegistry.swift` and `easld/internal/router/prompt_receipts.go` retain outcomes.
- `Sources/CanvasApp/ComposerController.swift` separates unknown submissions from editable drafts.
- There is no legacy resend fallback on an old host. A missing method must not cause duplicate execution.
- Preserve intermediate failure captures. A final cleared composer alone cannot prove exactly-once delivery.
- Stop only recorded owned probe processes. Export receipts before removing scratch.
