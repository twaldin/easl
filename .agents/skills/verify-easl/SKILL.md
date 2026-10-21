---
name: verify-easl
description: Verify easl's native macOS windows, terminal and composer input, browser relay, remote boards, and CLI behavior in a claimed GUI guest. Use before making GUI claims or qualifying a change for merge.
---

# Verify easl in a guest

This repo keeps project skills in `.agents/skills/`, not `.cursor/skills/`. Read [the feature map](features/README.md) before choosing a journey. Run only the journeys needed for the claim, and name every untested entry point.

## Hard rules

- Run all GUI launches, input, and captures inside a claimed `agent-gui` or `agent-gui-2`. Never put an easl window on twaldin-home's display, even hidden. Never move its Spaces, focus, or windows.
- Never touch Tim's `/Applications/easl.app` or connect to `easld@tim`. Use only guest-local scratch easld servers. Never SSH to twaldin-work.
- Never register a bundle with LaunchServices on home. `scripts/dev.sh` calls `dev-bundle.sh`, which calls `lsregister`, so both belong in the guest. Headless builds on home are not permission to run either launcher there.
- Keep guests muted. The current claim helper mutes the selected guest on boot. Never change home's audio. Use `screencapture -x` for any native capture to suppress the shutter sound.
- Kill only recorded, verified owned PIDs. Never use `pkill`, `killall`, names, bundle IDs, or a port alone. Never delete shared lock inodes or preempt another holder.
- Build with at most two jobs. Keep each frozen bundle until the run ends. Do not delete a binary while Gatekeeper may still scan it.
- Keep small records under `/home/tim/agents/projects/easl/state/lanes/$LANE/`. Keep bulk evidence under `/home/tim/lane-evidence/easl/$LANE/`. No gists or uploads. Never read secret or authentication-file contents.

## Launch

### Claim a guest from the queue

Run these commands on the Linux lane machine. `S` is the live support directory, not a copy of this skill. Read `$S/recipe.md` for current provisioning and recovery details. If it or the helpers are missing, report the missing prerequisite. Never substitute a host launch.

```sh
S=/home/tim/agents/projects/easl/state/efforts/gui-guest
LANE="$TSTACK_LANE"
E="/home/tim/lane-evidence/easl/$LANE"
mkdir -p "$E"
ssh -o BatchMode=yes twaldin-home 'mktemp -d /tmp/easl-verify.XXXXXX'
```

Record the returned home scratch path as `H`. Copy the **current** helper before every new queue wait. Do not reuse an old scratch copy.

```sh
scp "$S/claim.py" "$S/screen-sampler.swift" "$S/forward-local.py" \
  "$S/guest-forward.py" "$S/seed-local.py" "$S/window.swift" \
  "$S/cleanup-guest.py" "$S/verify-cleanup.py" twaldin-home:"$H/"
ssh -o BatchMode=yes twaldin-home "swift $H/screen-sampler.swift $H/screen.jsonl $H/stop"
```

Keep the sampler in a separate long-running job. Wait for `SAMPLER_READY`. Record its PID using `lsof -t "$H/screen.jsonl"` on home. Then keep this lifecycle shell open through cleanup:

```sh
ssh -t -o BatchMode=yes twaldin-home \
  "python3 -u $H/claim.py --guest any --boot --wait 900 $LANE $H -- /bin/zsh -l"
```

Require `acquired`, `booted`, and `guest-silent`. The helper boots without a display or VNC viewer. It never adopts an already-running guest. Copy the concrete `EASL_GUI_GUEST` from the acquired shell into every other terminal. Never pass `any` to SSH or `guest.py`.

Between **every GUI step**, run on the lane machine:

```sh
ssh -o BatchMode=yes twaldin-home "python3 $H/claim.py status"
```

If your continuous hold is at least 3,600 seconds and anyone is queued, finish the current step, clean up fully, and rejoin the queue. Do not reset the clock for another step. Hold the claim only for guest preparation and GUI proof, not writing, review, or CI. The helper monitors pressure during overlapping guest use; never stop the other holder's guest.

In the claimed home shell, set `H` and `LANE` to the recorded values, then:

```sh
SSH_CONFIG="$HOME/.config/agent-gui/ssh_config"
printf '%s\n' "$EASL_GUI_GUEST"
ssh -F "$SSH_CONFIG" -o BatchMode=yes "$EASL_GUI_GUEST" 'mktemp -d /tmp/ev.XXXXXX'
```

Record this boot's guest scratch as `G`. Copy helpers and acquire the guest-internal claim. Keep this second shell open too:

```sh
scp -F "$SSH_CONFIG" "$H/claim.py" "$H/guest-forward.py" "$H/seed-local.py" \
  "$H/window.swift" "$H/cleanup-guest.py" "$H/verify-cleanup.py" "$EASL_GUI_GUEST:$G/"
ssh -t -F "$SSH_CONFIG" -o BatchMode=yes "$EASL_GUI_GUEST" \
  "EASL_GUI_GUEST=$EASL_GUI_GUEST python3 -u $G/claim.py --wait 900 $LANE $G -- /bin/zsh -l"
```

Inspect previous-owner records. A lock without a live metadata record is still held. Follow the live recipe's explicit named-owner recovery if necessary. Never delete someone else's scratch or change their checkout.

### Build the exact revision and open an empty local board

All commands below, through guest cleanup, run in a **guest login shell**. Set `G`, `LANE`, and `BRANCH` to your recorded scratch, lane, and pushed branch. Use `/Users/lume/easl-gui/repo` as the persistent checkout. Clone it from `https://github.com/twaldin/easl.git` only if absent. Keep the checkout and `.build` between lanes.

```sh
R=/Users/lume/easl-gui/repo
cd "$R"
git status --porcelain
```

Require empty output before changing revisions. Stop if dirty or if an unowned compiler or instance still uses the checkout. Do not force a switch, reset, or remove the cache.

```sh
git fetch origin "$BRANCH"
git switch --detach "origin/$BRANCH"
HEAD=$(git rev-parse HEAD)
printf '%s\n' "$HEAD" > "$G/head.txt"
sw_vers
swift --version
bun --version
go version
zmx --version
EASL_BUNDLE_APP="$G/frozen.app" scripts/bundle.sh
(cd easld && go build -p 2 -o "$G/easld" ./cmd/easld)
ln -s "$R" "$G/repo"
mkdir -p "$G/local-board" "$G/proof"
export EASL_DEV_HOME="$G/view"
export EASL_DEV_APP="$G/frozen.app"
export EASL_DEV_DOWNLOADS="$G/downloads"
export EASL_DEV_EXTERNAL_OPEN=log
EASL_DEV_FRAME="0 0 1200 760" scripts/dev.sh start "$G/local-board"
scripts/dev.sh cli system.ping
scripts/dev.sh cli board.get
```

Retain command output, build logs, tool versions, head, and hashes in `proof`. Require Swift 6.4 when the task requires it. The short development home isolates boards, sockets, browser profiles, zmx sockets, state, and temporary files. It is **not** a replacement for the macOS account's `HOME`. Do not inherit installed easl data. A fresh home opens **Get Started**. Capture it, then press the fresh AX button labelled **Close Get Started** using the background action described under Drive. It is board content, not a separate window to close. For a non-onboarding study, seed only `{"dismissed":true}` in `$EASL_DEV_HOME/get-started.json` before launch and record that precondition.

Ready means the expected board root is selected, its native window has usable content, and a real input produces visible output. Socket existence or `system.ping` alone is not readiness. Retain an exact-window capture at readiness. Record signed executable hashes **after launch**; per-home signing can change executable bytes from the frozen source bundle.

If the compiler reports a stale precompiled module in the shared `.build`, retain that failure and leave the cache intact. Allocate a fresh build directory inside your recorded scratch with `export SWIFTPM_BUILD_DIR="$G/build"`. Require `swift build --show-bin-path` to name a path under it, then run the same bundling command there. Record this cold-build precondition and keep the selected build directory through the run. Never delete another lane's cache or accept an older binary after a failed build. Before launching, require `test -x "$G/frozen.app/Contents/MacOS/Easl"`. When using an SSH wrapper, retain the guest command's own exit status in its output as well as the controller exit status.

### Add a second instance

Keep the frozen app and checkout unchanged. Use a different development home and local root, never the first instance's home:

```sh
mkdir -p "$G/second-board"
EASL_DEV_HOME="$G/view-b" EASL_DEV_FRAME="20 20 1200 760" \
  scripts/dev.sh start "$G/second-board"
EASL_DEV_HOME="$G/view-b" scripts/dev.sh cli system.ping
EASL_DEV_HOME="$G/view-b" scripts/dev.sh cli board.get
```

Discover each home's PID and window independently. Run Doctor for both. Use an explicit home on every command targeting B. Two local boards alone do not exercise the relay. For that, attach both viewers to the same scratch board as [browser tiles](features/browser-tiles.md) specifies.

### Add guest-local scratch easld over loopback SSH

Use the recipe's **Forward only the existing guest identity** procedure. From a separate home login shell with `H`, `G`, and the concrete guest set:

```sh
export EASL_GUI_GUEST
python3 -u "$H/forward-local.py" "$H" "$G"
```

Require the public-fingerprint preflight, `loopbackSshExit: 0`, and `loopback-ssh-ok`. The helper forwards only the existing guest identity with a bounded dedicated agent. It writes the pinned loopback config and executable `$G/ssh` wrapper. Do not copy private keys, alter authorized keys, use home's general agent, or use the recipe's deckbox-server alternative. Keep forwarding alive until both viewers stop.

Start these as separate long-running **guest login-shell** jobs and record their actual PIDs:

```sh
"$G/easld" --home "$G/host" --own-terminals
```

Wait for its listening log and a successful `EASL_SOCKET="$G/host/easl.sock" bun "$R/cli/easl.ts" system.ping`. Then seed and serve the real fixture:

```sh
python3 "$G/seed-local.py" "$G"
python3 -m http.server 18765 --bind 127.0.0.1 --directory "$G/web"
```

The seed prints and saves actual board and tile IDs in `$G/tiles.json`. Record the board as `BOARD`. Restart the isolated viewer with the SSH overrides, which are stamped into its private bundle:

```sh
EASL_DEV_SSH="$G/ssh" EASL_DEV_REMOTE_HOME="$G/host" \
  EASL_DEV_FRAME="0 0 1200 760" scripts/dev.sh restart "$G/local-board"
scripts/dev.sh input remote easl-guest "$BOARD" "$G/host"
scripts/dev.sh cli board.get --board "$BOARD"
```

Require the remote tab's expected root, real shell output, and advancing HTML and browser counters in native pixels. The guest account must have macOS 14+, CLT, Python, Bun, Go, and zmx 0.8.1. A missing tool or failed loopback check is a failed prerequisite, not a reason to use a production host.

## Doctor

Run this read-only check before driving and whenever ownership or readiness looks wrong. On home, `python3 "$H/claim.py" status` must show your lane holding the concrete guest. In the guest, set `PID` from `$EASL_DEV_HOME/pid`, discover windows with `swift "$G/window.swift" "$PID"`, then set `WINDOW` to that PID's onscreen, layer-zero **board** window. Hidden panels are not the board. Run this block as one check and retain all output:

```sh
test "$(git -C "$R" rev-parse HEAD)" = "$(cat "$G/head.txt")" &&
test -z "$(git -C "$R" status --porcelain)" &&
test "$(cat "$EASL_DEV_HOME/pid")" = "$PID" &&
test "$(lsof -t "$EASL_DEV_HOME/instance.lock")" = "$PID" &&
kill -0 "$PID" &&
ps -p "$PID" -o pid,ppid,command &&
lsof -a -p "$PID" "$EASL_DEV_HOME/easl.sock" &&
shasum -a 256 "$EASL_DEV_HOME/easl.app/Contents/MacOS/Easl" &&
swift "$G/window.swift" "$PID" &&
cat "/tmp/easl-gui-claims/$LANE.json" &&
scripts/dev.sh cli system.ping &&
scripts/dev.sh cli board.get
```

Require the executable command to name your private bundle, the hash to match the post-launch receipt, the window's PID and ID to match `PID` and `WINDOW`, and the selected root to match the intended board. Verify the guest claim record names your lane and `G`, and its recorded `holderPid` is alive. The guest-internal claim uses the legacy `agent-gui` record even on `agent-gui-2`; home status is the authority for the concrete VM.

If using easld, include `cat "$G/host/instance.lock"`, `lsof -t "$G/host/instance.lock"`, `ps -p "$SERVER_PID" -o pid,command`, and a ping against `$G/host/easl.sock`. Require both lock values to equal your recorded `SERVER_PID`, with the command naming `$G/easld --home $G/host`. Do not drive on a mismatch. Doctor inspects only; it never repairs, relaunches, or kills.

## Drive

Use `scripts/dev.sh input` for native instance-queue input. It exercises hit testing, the Hyper monitor, key equivalents, menus, and the responder chain without global mouse or keyboard events. Use `scripts/dev.sh cli` for CLI actions against that instance's socket. Clear inherited `EASL_TILE_ID` and `EASL_BOARD_ID` when running an external controller, then supply explicit board IDs where needed. For the scratch daemon, use `EASL_SOCKET="$G/host/easl.sock" bun "$R/cli/easl.ts" ...`.

Prefer menu titles, keys, accessibility labels, and object IDs over coordinates:

```sh
scripts/dev.sh input mainmenu "File/New Terminal"
scripts/dev.sh input shortcut i --mods cmd --window "$WINDOW"
scripts/dev.sh input text "a draft" --window "$WINDOW"
scripts/dev.sh input key return --mods cmd --window "$WINDOW"
scripts/dev.sh input key escape --window "$WINDOW"
scripts/dev.sh input state
scripts/dev.sh cli view.get
```

Use **Prompt** and the target button's current label in a fresh CuaDriver accessibility tree. An AX action uses that snapshot's `element_token`, the same session, exact PID and window, and `delivery_mode: background`; see `Tests/RemoteClosedBoard/native.py` for the existing `click` request shape. Never reuse a token after another snapshot. A synchronous target popup can outlive an AXPress timeout. Capture its native menu before deciding that it failed. `mainmenu` invokes a real menu action but does not prove the menu's visual layout or physical keyboard navigation.

Menu paths separate levels with `/`. Escape a literal slash inside a title as `//`. A newly created shell can have no `name` in `agent.list`; its current target title is then its directory. Read the actual **Only …** menu item in the fresh AX tree rather than guessing it from the tile ID.

For canvas gestures without an accessibility action, derive coordinates from a fresh own-window capture and `view.get`. Record the geometry. Replay coordinates are top-left **content points**, not screenshot pixels or board coordinates. At scale 2, divide pixels by 2 and subtract measured chrome, usually 28 points or 64 with tabs. Verify actual bounds rather than assuming those offsets. Examples with measured `X`, `Y`, `TO_X`, and `TO_Y`:

```sh
scripts/dev.sh input click "$X" "$Y" --mods hyper --window "$WINDOW"
scripts/dev.sh input drag "$X" "$Y" "$TO_X" "$TO_Y"
scripts/dev.sh input shortcut m
scripts/dev.sh input menu "$X" "$Y" "Content Zoom/150%"
```

`--window` is supported for click, text, key, and shortcut. Other input kinds use the instance's selected board; confirm it with `input state` first. Do not use internal setters, direct draft mutation, or `agent.prompt` to stand in for a composer gesture. API calls may seed fixtures and inspect side effects, but cannot prove a different native entry point.

## Evidence

Create a new run directory for every attempt. Never overwrite before, intermediate, failed, or settled captures. Record the claim, feature ID, entry point, head SHA, guest, build log, frozen bundle hash, signed launched executable hash, PID, window ID, socket, action transcript, and capture receipt. Record app logs and the board or terminal readback needed to prove side effects. Tie every result to the exact tested SHA, not whichever branch later merges.

In the guest, set `SESSION` to a run-unique name. Set `CAPTURE` to an unused absolute PNG path under `$G/proof`. Use the authorized CuaDriver, not a new daemon or permission grant:

```sh
test ! -e "$CAPTURE" &&
/Applications/CuaDriver.app/Contents/MacOS/cua-driver call get_window_state \
  "{\"pid\":$PID,\"window_id\":$WINDOW,\"include_accessibility_tree\":true,\"max_image_dimension\":0,\"screenshot_out_file\":\"$CAPTURE\",\"session\":\"$SESSION\"}"
```

Retain stdout as a separate unused JSON receipt. Require response PID and window ID to match, `screenshot_frame_valid: true`, nonempty capture and snapshot IDs, and distinct IDs between captures. Export and **open the actual PNGs**. Inspect the before state, action or intermediate state, and resulting pixels. Check real file contents or terminal/session receipts too. A file existing, a spinner disappearing, `view.snapshot`, `view.render`, or unit tests passing is never GUI proof. AppKit-only regressions can supplement, not replace, WindowServer pixels.

`dev.sh shot "$UNUSED_PATH"` is a WindowServer capture using `screencapture -x`, but needs yabai and can overwrite a destination. Prefer exact-PID/window CuaDriver here. Never pursue an SSH Screen Recording grant or capture another app.

For timing, separate input-to-first-visible, input-to-assignment, and input-to-settled-sharp. State capture and accessibility-walk cost, whether it is inside the interval, and clock domain. PNG completion time includes capture overhead and is not first presentation. Use the two-gate observer and denominator rules in [browser tiles](features/browser-tiles.md) and [performance](performance.md). Do not report a speedup from screenshots alone.

Export before deleting scratch. On the lane machine, with the concrete guest and recorded `H`, `G`, and `E`:

```sh
ssh -o BatchMode=yes twaldin-home \
  "scp -r -F /Users/twaldin/.config/agent-gui/ssh_config $EASL_GUI_GUEST:$G/proof $H/"
scp -r -o BatchMode=yes twaldin-home:"$H/proof" "$E/"
```

Use a fresh evidence subdirectory on subsequent attempts. Compare hashes across export. Keep secrets, authentication files, and agent sockets out. After a squash merge, record the merge SHA and compare its tree to the reviewed head. If the tested and reviewed heads differ, record the changed paths and rerun affected journeys. Never relabel old images as proof of a new head.

## Cleanup

Run cleanup after **every** failed attempt as well as success. Keep the claim while cleaning. Do not stop the guest before exporting evidence and cleanup receipts.

1. End only your CuaDriver session with `cua-driver call end_session "{\"session\":\"$SESSION\"}"`.
2. Stop B with `EASL_DEV_HOME="$G/view-b" scripts/dev.sh stop` if created, then A with `scripts/dev.sh stop`. Verify their recorded PIDs exit and owned zmx sessions end. Stopping the app alone does not end persistent shells.
3. For the unmodified `seed-local.py` fixture, `python3 "$G/cleanup-guest.py" "$G"` stops A, closes its remote board with `endSessions:true`, verifies and stops scratch easld and HTTP owners, and requests forwarding release. It assumes `$G/view`, `$G/tiles.json`, and port 18765. Do **not** run it against a partial or different fixture. For those, close every recorded scratch board through its socket with `board.close --board "$BOARD" --endSessions true`, verify each recorded daemon or HTTP PID's command and lock, send SIGTERM to those PIDs, and wait for exit. Touch `$G/release-agent` after viewer shutdown if forwarding was started.
4. Stop any additional owned stub, observer, fault relay, or shaper. Restore network state as [performance](performance.md) specifies. No pattern kills.
5. Exit the guest-internal claim shell and require `released`. Wait for forwarding to exit. For a forwarded fixture, run `python3 "$S/guest.py" --guest "$EASL_GUI_GUEST" "test ! -e /tmp/easl-gui-claims/$LANE.json && python3 $G/verify-cleanup.py $G $LANE"` on the lane machine. Require released locks, no forwarded socket, and loopback auth failure after agent teardown. Check the recorded dedicated agent PID is gone on home and its socket is absent.
6. Export app/build logs, hashes, action and capture receipts, and cleanup output into `proof`, then export `proof`. Verify the lane-machine evidence opens and hashes match. Remove exactly the recorded `G`, never the shared checkout or `.build`.
7. Exit the home lifecycle shell. Require the helper's verified guest stop and `released`. Confirm with `lume ls` on home. Only then touch `$H/stop` and wait for the sampler to exit.
8. Export the sampler and home cleanup records. Inspect for owned windows, focus changes, and Space changes. Report actual sample cadence and maximum gap, not uninterrupted observation. Remove exactly your recorded `H` after release and export.
9. On the lane machine, reopen the retained before and after PNGs and check their hashes again. Confirm the evidence survives cleanup at `$E`. Report what was exercised, what failed, and what remains untested.

## Maintain the map

When a user path, menu, shortcut, CLI contract, or prerequisite changes, update its feature file in the same change. Use `/maintain-verification-skill` to check the map against the app. Do not turn an unreachable journey into a passing one by substituting a convenient entry point.
