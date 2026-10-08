# Key-path measurement design — macOS 26, SIP enabled

## Decision and scope

Start with two root-free differential experiments below; ask the shepherd for a short `fs_usage` capture if the residual is still large. **Do not attribute the existing 150–185 ms residual to Ghostty/zmx yet.** The probe's “post” timestamp is actually taken **before launching `scripts/dev.sh`**, whose `running_pid` calls `lsof` before it execs the input poster. AppKit creates its NSEvent timestamp only after distributed-notification delivery. Those upstream costs are outside `key.wait` and `key.handle` and therefore survive the subtraction.

Most likely dominant *measured* hop, pending the experiments: **probe timestamp → launcher/PID lookup → distributed-notification replay**, not a deliberate Ghostty or zmx input timer. This is an inference from source, not a new measurement. If an actual timestamp at `ghostty_surface_key` still leaves 150–185 ms, first suspect IO-thread/reader scheduling or blocking work, not a fixed poll interval: neither input implementation has such an interval.

Research only was performed: no builds, application launches, tracing, or experiment executions. No repo worktree was edited. This design and the scratch-path registration are the deliverables. Source copies are in `/Users/twaldin/dev/easl-lanes/perf-lead/scratch.cO7Yit`, registered in `scratch-paths.txt`.

## Pinned source identities

- **zmx 0.8.1**: tag `v0.8.1` resolves to commit [`8bab1f0173b07e79835ea372d749af3dbf0d0842`](https://github.com/neurosnap/zmx/commit/8bab1f0173b07e79835ea372d749af3dbf0d0842). All zmx links below use that commit, not `main`.
- Homebrew tap formula revision [`1568b3dc601503143c392e3c413b75018a457893`, `Formula/zmx.rb:1-15`](https://github.com/neurosnap/homebrew-tap/blob/1568b3dc601503143c392e3c413b75018a457893/Formula/zmx.rb#L1-L15) specifies version `0.8.1`. On this arm64 Mac it downloads **a prebuilt binary**, not a source archive: `https://zmx.sh/a/zmx-0.8.1-macos-aarch64.tar.gz`, SHA-256 `1d86b1c9fba47fa707a6f0e976b20510b07c1c26d0ed010b9414b2a2c5e6beef`. The Intel URL is `https://zmx.sh/a/zmx-0.8.1-macos-x86_64.tar.gz`, SHA-256 `3208578ad91d8a62077772dc8a1369a92033d9e84169bac673ef8542b6ff9707`. The formula's release number matches the source tag; it does not independently attest the running daemon's version. Use a fresh isolated session for experiment B, not a possibly older surviving daemon.
- **Ghostty**: local `Vendor/libghostty-spm/Package.swift:51-54` pins `upstream.3c47ca159368-2/GhosttyKit.xcframework.zip`, checksum `804d4c92cad153eb8d85ed86f4c98ca587e90ff47ac0a62c846c985ece02a9c3`. The [release metadata](https://github.com/Lakr233/libghostty-spm/releases/tag/upstream.3c47ca159368-2) identifies upstream commit **`3c47ca159368eb4a860ffe5333abdf4a85b2767b`**. All Ghostty links below use it.
- That Ghostty revision pins libxev **`9ce8e8e6ff89e583258a7f8e7adeeeaeae8611bf`**, in [`build.zig.zon:13-17`](https://github.com/ghostty-org/ghostty/blob/3c47ca159368eb4a860ffe5333abdf4a85b2767b/build.zig.zon#L13-L17).
- Local easl references in this document are relative to `~/dev/easl-lanes/perf-main`. The measured app may be a different frozen lab bundle; its existing aggregate metrics are useful, but source in this checkout is not proof that a particular per-key trace exists in that bundle.

## What the input code actually does

### zmx attach → socket → daemon → program PTY

1. Attach connects to the session and switches stdin to raw mode: `cfmakeraw`, **`VMIN=1`, `VTIME=0`**, `TCSANOW`. There is no canonical newline wait or decisecond read timeout ([`src/main.zig:1589-1641`](https://github.com/neurosnap/zmx/blob/8bab1f0173b07e79835ea372d749af3dbf0d0842/src/main.zig#L1589-L1641)).
2. The client makes its socket and stdin nonblocking. Outgoing socket and stdout buffers initially have **4096-byte capacity**; stdin is read into a **4096-byte array** ([`src/loop.zig:35-67`](https://github.com/neurosnap/zmx/blob/8bab1f0173b07e79835ea372d749af3dbf0d0842/src/loop.zig#L35-L67), [`110-133`](https://github.com/neurosnap/zmx/blob/8bab1f0173b07e79835ea372d749af3dbf0d0842/src/loop.zig#L110-L133)). A buffer's capacity is not a fill-before-send threshold.
3. Client waits with **`poll(..., -1)`**: indefinitely until fd readiness, not polling every N milliseconds. After stdin becomes readable it calls `read`, appends an IPC `.Input` message, and writes buffered socket bytes on `POLLOUT` ([`src/loop.zig:72-126`](https://github.com/neurosnap/zmx/blob/8bab1f0173b07e79835ea372d749af3dbf0d0842/src/loop.zig#L72-L126), [`183-197`](https://github.com/neurosnap/zmx/blob/8bab1f0173b07e79835ea372d749af3dbf0d0842/src/loop.zig#L183-L197)). If the outgoing buffer was empty when the poll set was built, its newly appended input flushes on the **next loop iteration**, whose writable socket makes poll return promptly. It does not wait for the next key or a timer.
4. IPC uses a packed header with `tag: u8` and `len: u32`; serialization uses **`@sizeOf(Header)`**, so do not assume a five-byte native packed-struct image. Input's tag is zero. Header and payload are appended immediately; receive buffers start at 4096 bytes and each socket `read` uses a 4096-byte temporary buffer ([`src/ipc.zig:6-8,41-44`](https://github.com/neurosnap/zmx/blob/8bab1f0173b07e79835ea372d749af3dbf0d0842/src/ipc.zig#L6-L44), [`116-132`](https://github.com/neurosnap/zmx/blob/8bab1f0173b07e79835ea372d749af3dbf0d0842/src/ipc.zig#L116-L132), [`177-215`](https://github.com/neurosnap/zmx/blob/8bab1f0173b07e79835ea372d749af3dbf0d0842/src/ipc.zig#L177-L215)). Capture byte counts rather than guessing the framing length.
5. The daemon also waits with **`poll(..., -1)`**. Receiving `.Input` queues its payload in `pty_write_buf`; a leader client sends the full payload. The buffer cap is **256 KiB**, not a batching target. Once nonempty, the next poll set includes PTY `POLLOUT`; the daemon writes until the buffer empties or the PTY would block ([`src/loop.zig:268-292`](https://github.com/neurosnap/zmx/blob/8bab1f0173b07e79835ea372d749af3dbf0d0842/src/loop.zig#L268-L292), [`418-428`](https://github.com/neurosnap/zmx/blob/8bab1f0173b07e79835ea372d749af3dbf0d0842/src/loop.zig#L418-L428), [`448-469`](https://github.com/neurosnap/zmx/blob/8bab1f0173b07e79835ea372d749af3dbf0d0842/src/loop.zig#L448-L469), [`866-908`](https://github.com/neurosnap/zmx/blob/8bab1f0173b07e79835ea372d749af3dbf0d0842/src/loop.zig#L866-L908)). This is another readiness-loop turn, not a time-based throttle.
6. No active per-byte IO trace exists in these paths. The debug statements containing byte data in `queuePtyInput` and `handleInput` are **commented out** (`src/loop.zig:883-896`). `src/main.zig:21-24` sets debug log level at compile time; no runtime `ZMX_DEBUG`/`ZMX_TRACE` switch is used by the input loop. `ZMX_LOG_MODE` is a **file permission mode**, not log verbosity. Logs use **whole-second wall timestamps** (`now.toSeconds()`), too coarse for this question ([`src/log.zig:77-98`](https://github.com/neurosnap/zmx/blob/8bab1f0173b07e79835ea372d749af3dbf0d0842/src/log.zig#L77-L98), [`src/cfg.zig:23-37`](https://github.com/neurosnap/zmx/blob/8bab1f0173b07e79835ea372d749af3dbf0d0842/src/cfg.zig#L23-L37)). Startup logging can identify the client socket fd and daemon PTY fd (`src/loop.zig:19,229`), but cannot timestamp successful bytes.
7. A **500 ms sleep** exists for SIGHUP→SIGKILL shutdown grace (`src/loop.zig:1073`), not steady-state input. The daemon PTY-output read buffer comment about Linux `N_TTY_BUF_SIZE` is not evidence of a macOS input delay.

### ghostty_surface_key → IO mailbox → PTY master write

1. Swift calls the C API synchronously at `Vendor/libghostty-spm/Sources/GhosttyTerminal/Surface/TerminalSurface.swift:32-42`. The C entry passes through `App.keyEvent` into `core_surface.keyCallback` ([`src/apprt/embedded.zig:2033-2043`](https://github.com/ghostty-org/ghostty/blob/3c47ca159368eb4a860ffe5333abdf4a85b2767b/src/apprt/embedded.zig#L2033-L2043), [`202-220`](https://github.com/ghostty-org/ghostty/blob/3c47ca159368eb4a860ffe5333abdf4a85b2767b/src/apprt/embedded.zig#L202-L220)).
2. `Surface.keyCallback` encodes the key and queues `.write_small`, `.write_stable`, or `.write_alloc` ([`src/Surface.zig:2840-2859`](https://github.com/ghostty-org/ghostty/blob/3c47ca159368eb4a860ffe5333abdf4a85b2767b/src/Surface.zig#L2840-L2859)). Small encodings fit inline; encode options take the renderer-state mutex (`src/Surface.zig:3233-3255,3301-3306`). `key.handle ≈ 0.1 ms`, as reported, argues against a long synchronous block for those samples.
3. `queueIo` calls `Termio.queueMessage`, which **sends the message then calls `mailbox.notify()` immediately** ([`src/Surface.zig:857-878`](https://github.com/ghostty-org/ghostty/blob/3c47ca159368eb4a860ffe5333abdf4a85b2767b/src/Surface.zig#L857-L878), [`src/termio/Termio.zig:411-426`](https://github.com/ghostty-org/ghostty/blob/3c47ca159368eb4a860ffe5333abdf4a85b2767b/src/termio/Termio.zig#L411-L426)). The threaded mailbox is a **64-message SPSC queue**, with `xev.Async` wakeup ([`src/termio/mailbox.zig:11-44`](https://github.com/ghostty-org/ghostty/blob/3c47ca159368eb4a860ffe5333abdf4a85b2767b/src/termio/mailbox.zig#L11-L44)). A full queue has a wake-and-wait slow path; it is not a normal input batching delay (`src/termio/mailbox.zig:70-95`).
4. The IO thread registers the wakeup, runs its event loop, drains the mailbox when awakened, and calls `io.queueWrite` for the write messages ([`src/termio/Thread.zig:272-279`](https://github.com/ghostty-org/ghostty/blob/3c47ca159368eb4a860ffe5333abdf4a85b2767b/src/termio/Thread.zig#L272-L279), [`350-366`](https://github.com/ghostty-org/ghostty/blob/3c47ca159368eb4a860ffe5333abdf4a85b2767b/src/termio/Thread.zig#L350-L366), [`454-471`](https://github.com/ghostty-org/ghostty/blob/3c47ca159368eb4a860ffe5333abdf4a85b2767b/src/termio/Thread.zig#L454-L471)). Its **25 ms coalescing timer is for resizes**, not input writes (`src/termio/Thread.zig:27-33,390-406`).
5. Exec chunks outgoing data into **64-byte pooled write buffers** and calls libxev `write_stream.queueWrite`; successful-write logging is **commented out** ([`src/termio/Exec.zig:403-489`](https://github.com/ghostty-org/ghostty/blob/3c47ca159368eb4a860ffe5333abdf4a85b2767b/src/termio/Exec.zig#L403-L489), [`498-507`](https://github.com/ghostty-org/ghostty/blob/3c47ca159368eb4a860ffe5333abdf4a85b2767b/src/termio/Exec.zig#L498-L507)). The first queued request is added to the loop immediately; later requests preserve FIFO order ([libxev `src/watcher/stream.zig:874-879`](https://github.com/mitchellh/libxev/blob/9ce8e8e6ff89e583258a7f8e7adeeeaeae8611bf/src/watcher/stream.zig#L874-L879)). On its macOS kqueue path, actual completion work invokes `write(2)` ([`src/backend/kqueue.zig:1162-1166`](https://github.com/mitchellh/libxev/blob/9ce8e8e6ff89e583258a7f8e7adeeeaeae8611bf/src/backend/kqueue.zig#L1162-L1166)). There is no intentional 150 ms input flush timer in this chain.
6. macOS libxev Async uses a **Mach message with send timeout zero** to wake the loop. Wake notifications may coalesce, but the callback drains pending messages; this is not timed key coalescing ([`src/watcher/async.zig:306-311,397-422`](https://github.com/mitchellh/libxev/blob/9ce8e8e6ff89e583258a7f8e7adeeeaeae8611bf/src/watcher/async.zig#L306-L422)).
7. `GHOSTTY_LOG` selects **destinations**, not additional IO instrumentation: its fields are `stderr` and `macos` ([`src/global.zig:148-154,394-402`](https://github.com/ghostty-org/ghostty/blob/3c47ca159368eb4a860ffe5333abdf4a85b2767b/src/global.zig#L148-L154)). Release builds keep debug logs compiled out even with that variable ([`src/main_ghostty.zig:201-213`](https://github.com/ghostty-org/ghostty/blob/3c47ca159368eb4a860ffe5333abdf4a85b2767b/src/main_ghostty.zig#L201-L213)). `GHOSTTY_LOG=stderr=true,macos=true` may expose existing logs, but cannot enable the commented IO-write statements. Debug builds have `mailbox message=write_small` logs (`src/termio/Thread.zig:313`), which mark dequeue, not the completed syscall or payload.
8. The Swift wrapper's `TerminalDebugLog` is disabled by default, enabled programmatically, and stamps wall time to milliseconds (`Debug/TerminalDebugLog.swift:43-49,81-101,213-215`). Its key log occurs **after** `ghostty_surface_key` returns (`Surface/TerminalSurface.swift:37-41`); it is not a PTY-write timestamp and has no env-var switch in that logger. Enabling it would require a dev-only code/runtime change, not this read-only plan.

## The upstream measurement confound

- `key-path-probe.py:55-59` stamps `time.monotonic_ns()` before `inst.dev("input", "key", "a")`.
- `scripts/perf-loop.py:173-174` runs `scripts/dev.sh`; `scripts/dev.sh:64-70` looks up the owning PID using **`cat`, `lsof`, and `grep`**; only then does `scripts/dev.sh:201-204` exec `.build/dev-input`.
- `scripts/dev-input.swift:51-98` builds a string dictionary and posts **`canvas.dev.input` through `DistributedNotificationCenter`** with `deliverImmediately: true`. **It prints no timestamp, and carries no sender timestamp.** It then sleeps **150 ms after posting** (`:99-100`). That sleep extends caller completion and the real interval between invocations; it does **not by itself** delay an already-posted byte's independently recorded program timestamp.
- The app observes on **`.main`** (`Sources/CanvasApp/DevInput.swift:44-49`), creates keyDown and keyUp NSEvents and calls `NSApp.postEvent(..., atStart: false)` (`:275-277`). NSEvent timestamps are **app-side system uptime at event creation**, not sender time (`:414-427`). Consequently `key.wait` excludes launcher and notification delivery.
- The old probe's explicit `sleep(0.1)` is **after** the blocking tool call. It is not proof of 100 ms post spacing. The persistent sender below posts on a 100 ms schedule and stamps its **actual** posts.
- An old sample cannot be retrospectively corrected exactly: its sender timestamp was never recorded. Do not subtract 150 ms blindly, or subtract an aggregate `key.wait` mean from a post→program median and call that a per-key split. Use paired timestamps or report the quantities separately.

## Timestamp map: cheapest trustworthy boundary per hop

Let `L` = old probe pre-launch stamp, `S` = true sender post bracket, `E` = app-created NSEvent, `K` = C API entry, `G` = Ghostty PTY write, `A` = attach stdin read, `C` = attach socket write, `D` = daemon socket read, `W` = daemon PTY write, `P` = program read.

| Boundary / component | Cheapest timestamp with the existing lab | What it proves / limitation |
|---|---|---|
| `L → S`: launcher/PID lookup/process startup | Persistent Python Foundation poster below stamps immediately before/after the same notification API. For a future instrumented poster, record both `L` and `S` per invocation. | Eliminates the launcher from new measurements. The original binary exposes no `S`; measuring its process exit is not a post stamp. |
| `S → E → K`: notification delivery, AppKit queue, handler | Keep the existing `key.wait`/`key.handle` metrics as aggregate context; optionally shepherd's DTrace **pid-provider** probe on exported `ghostty_surface_key` for exact `K`. | No existing trustworthy root-free per-key `E`/`K` timestamp is exposed by these source files. The root-free experiment reports this part combined with Ghostty/outer PTY, not falsely isolated. |
| `K → G`: encode, mailbox wake, IO-thread scheduling, PTY master write | Shepherd's syscall trace on dev-easl's PTY-master fd; optional `ghostty_surface_key` entry probe gives `K`. | No successful-write env log. `fs_usage` observes `G` but alone has no `K`. Separating enqueue/dequeue further needs a usable function probe or new instrumentation; no stable exported API for that internal boundary is assumed. |
| `G → A`: outer PTY and attach reader scheduling | Same capture: successful easl `write` and attach `read(fd=0)`; root-free A replaces the reader with a stamped relay on the **same slave**. | Receiver timestamp includes wake/scheduling and the read, not just kernel transport. A separate process consuming a PTY is not a passive tap. Suspend the real lab reader first. |
| `A → C`: zmx client processing and socket readiness | Shepherd traces attach `read(0)` and `write(socket_fd)`. | No byte log. Root-free B measures the whole zmx path, not this hop alone. |
| `C → D`: Unix socket and daemon scheduling | Shepherd traces attach socket `write` and daemon socket `read`. | Capture both PIDs and their correct fd pair; filesys-only filtering may miss socket operations. |
| `D → W`: daemon input queue/readiness turn | Shepherd traces daemon socket `read` and PTY-master `write`. | Input is queued for POLLOUT, not a timer. |
| `W → P`: inner PTY and program scheduling/read | Stamper's `time.monotonic_ns()` **immediately after `os.read`**; syscall trace makes the kernel read-return boundary available too. | User-space timestamp is an upper bound on read return; log-file write/watching delay is excluded because timestamp is inside the program. |
| Relay's own `in → out` in experiment A | Python stamps outer `read` return, inner `write` entry and return before any relay file logging. | Measured relay overhead, not assumed zero. Program may read before the writer's syscall returns; use entry→read for an upper-bound transport+scheduling quantity. |

For exact successful reads, use **return**, not entry: a stamper may enter a blocking read long before a key exists. For writes, retain **both entry and return**. A receiver can run before the writer returns, so negative `read_return − write_return` need not be a clock error; `read_return − write_entry` is the useful enclosing latency. Use monotonic timestamps throughout; keep wall/monotonic calibration pairs only for `fs_usage` alignment.

Python 3.10+ on macOS uses the same `mach_absolute_time`-based monotonic clock across processes ([Python `time.monotonic`](https://docs.python.org/3/library/time.html#time.monotonic)). Do not mix raw Mach ticks with nanoseconds, or continuous-time timestamps with absolute-time timestamps across sleep. Avoid machine sleep during a run.

## macOS tooling and the shepherd's exact commands

### Without root

- `log stream` can observe available unified logs as an ordinary user, subject to privacy/policy. For example:

  ```sh
  /usr/bin/log stream --style json --level debug --predicate "processIdentifier == $EASL_DEV_PID AND subsystem == 'com.mitchellh.ghostty'"
  ```

  This subscribes to **messages the program emitted**, not every `write(2)`. Ghostty's macOS log route is in [`src/main_ghostty.zig:124-148`](https://github.com/ghostty-org/ghostty/blob/3c47ca159368eb4a860ffe5333abdf4a85b2767b/src/main_ghostty.zig#L124-L148). `log(1)` locally documents stream/show vs root-required `config` (`/usr/share/man/man1/log.1:87-90,139-144`). Missing debug records do not prove missing IO.
- `fs_usage` explicitly requires root (`/usr/share/man/man1/fs_usage.1:20-26`). `dtrace` syscall observation also requires privilege; it is not made root-free by targeting one's own PID.
- `kdebug`/`ktrace` recording is not an unprivileged alternative. XNU's tracing ownership checks require superuser (or special private entitlement in development/debug kernels): [`bsd/kern/kern_ktrace.c:274-296,349-357`](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/kern_ktrace.c#L274-L296). This is a public-source authorization reference, not a claim that the running kernel was rebuilt from that exact commit. Reading a previously recorded trace is different from enabling one.
- LLDB can debug suitably authorized nonprotected user programs, but per-key breakpoints stop threads and perturb the latency being measured. Hardened-runtime/debug authorization can also prevent attachment. It is not the default timing instrument. Compiled interposition would need a helper build plus launch/codesigning accommodations, outside this no-build investigation.
- Root-free trustworthy options here are **timestamps in processes we control**, and isolated PTY substitutions. A passive observer cannot receive a copy of an existing PTY input stream by opening its slave: a second reader competes for bytes.

### First choice: shepherd runs fs_usage, with SIP left on

Resolve only the **isolated dev instance**, its attach client, its session daemon, and its stamper. Never select all `easl`, all `zmx`, or Tim's live PID. Before the timed run, save the fd map:

```sh
/usr/sbin/lsof -nP -a -p "$EASL_DEV_PID,$ZMX_ATTACH_PID,$ZMX_DAEMON_PID,$STAMPER_PID" > "$LAB/fds.txt"
```

Use the daemon startup log's `pty_fd=` and attach log's `client loop fd=` as additional checks. `lsof` runs **outside** the measured key burst.

**Exact 20-second shepherd one-liner (requires sudo):**

```sh
sudo /usr/bin/fs_usage -w -t 20 "$EASL_DEV_PID" "$ZMX_ATTACH_PID" "$ZMX_DAEMON_PID" "$STAMPER_PID" > "$LAB/fs-usage.log"
```

This deliberately omits `-f` to retain PTY **and socket** events. For just the PTY operations:

```sh
sudo /usr/bin/fs_usage -w -f filesys -t 20 "$EASL_DEV_PID" "$ZMX_ATTACH_PID" "$ZMX_DAEMON_PID" "$STAMPER_PID" > "$LAB/fs-usage-pty.log"
```

**There is no `fs_usage -p` option on this Mac. PIDs are positional**, unlike `ktrace -p` or `dtrace -p` (`/usr/share/man/man1/fs_usage.1:10-19,127-129`). Wide output has time-of-day, syscall, `F=<fd>`, requested byte count, elapsed syscall time and thread identity (`:137-179`); it does not include payload bytes. Identify dev-easl writes to its outer PTY master, attach reads on fd 0, attach writes to its socket, daemon reads from that socket, daemon writes to its inner PTY master, and stamper reads on fd 0. Do not mistake stamper's **log-file** writes or terminal-output reads for input.

Apple's [filesystem tracing guide](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/FileSystem/Articles/FileSystemCalls.html) documents the columns and filtering. Its old example says milliseconds; the installed manual says **microsecond granularity in wide mode**. Use actual capture precision, and include syscall elapsed duration when bracketing a boundary rather than treating screen-print time as event time. For an unambiguous entry/return split, prefer the DTrace command below if allowed. `W` means scheduled-out time is included, not that the syscall used that much CPU.

### Optional: shepherd's DTrace syscall entry/return one-liner

Use this when syscall provider access is available for the lab's nonprotected executables. It prints captured event timestamps, so DTrace's delayed/batched printing does not move the event timestamp. It records fds and actual return counts, avoiding payload copying and its SIP/privacy overhead.

```sh
sudo /usr/sbin/dtrace -q -n 'syscall::read:entry,syscall::read_nocancel:entry,syscall::write:entry,syscall::write_nocancel:entry /pid == $1 || pid == $2 || pid == $3 || pid == $4/ { self->kp = 1; self->fd = arg0; self->n = arg2; self->beg = timestamp; printf("%llu wall=%llu pid=%d tid=%d %s entry fd=%d requested=%llu\n", timestamp, walltimestamp, pid, tid, probefunc, self->fd, self->n); } syscall::read:return,syscall::read_nocancel:return,syscall::write:return,syscall::write_nocancel:return /self->kp/ { printf("%llu wall=%llu pid=%d tid=%d %s return fd=%d result=%lld errno=%d elapsed_ns=%llu\n", timestamp, walltimestamp, pid, tid, probefunc, self->fd, (int64_t)arg0, errno, timestamp-self->beg); self->kp = 0; } profile:::tick-20sec { exit(0); }' "$EASL_DEV_PID" "$ZMX_ATTACH_PID" "$ZMX_DAEMON_PID" "$STAMPER_PID" > "$LAB/syscalls.log"
```

Darwin's own `/usr/bin/dtruss:392-416` uses these four probe names and return conventions. The first read already blocked when tracing begins has no captured entry; its first return may be missing. Start capture before the burst and discard a warm-up key if needed; do not infer a gap from that omission.

For exact C API handoff `K`, a **separate optional** pid-provider capture is:

```sh
sudo /usr/sbin/dtrace -q -n "pid${EASL_DEV_PID}::ghostty_surface_key:entry { printf(\"%llu wall=%llu pid=%d tid=%d ghostty_surface_key entry\\n\", timestamp, walltimestamp, pid, tid); } profile:::tick-20sec { exit(0); }" > "$LAB/ghostty-key-entry.log"
```

Use the same key burst and monotonic clock as the syscall capture if both run. Match press/release order carefully: `dev-input` posts **both** keyDown and keyUp, whereas ordinary raw ASCII produces one input byte. Function entry alone does not identify the byte or action; pair the press calls with successful single-byte writes, not every entry indiscriminately. If the pid provider is blocked, unavailable, or the export cannot be probed, report `K` unavailable; do not claim the IO-thread delay was isolated. SIP prevents DTrace inspection of protected system processes even with sudo ([Apple runtime protections](https://developer.apple.com/library/archive/documentation/Security/Conceptual/System_Integrity_Protection_Guide/RuntimeProtections/RuntimeProtections.html)). **Do not disable SIP.** The first choice remains `fs_usage`, and the root-free experiments do not depend on either sudo command succeeding.

## Root-free experiments: common setup

The following are snippets for Tim to run **later**, not commands executed during this research. They require an existing Python 3.10+ and zmx 0.8.1, but **no compiler, root, PyObjC package, app rebuild, or live-app change**. Use the already-created single-tile isolated dev lab. Save all new files beneath an allowed scratch directory:

```sh
export REPO="$HOME/dev/easl-lanes/perf-main"
export LAB="$(mktemp -d "$HOME/dev/easl-lanes/perf-lead/scratch.XXXXXX")"
printf '%s\n' "$LAB" >> "$HOME/dev/easl-lanes/perf-lead/scratch-paths.txt"
# For experiment A only: select the existing isolated lab PID and its sole zmx attach PID.
# The relay additionally rejects an attach which is not a descendant of EASL_DEV_PID.
: "${EASL_DEV_PID:?Set this to the isolated lab easl PID, never the live app}"
: "${ZMX_ATTACH_PID:?Set this to that lab tile's zmx attach client PID, not its daemon}"
```

Create the stamper used by both experiments. It timestamps immediately after each raw read; each byte in one returned chunk receives that read's timestamp. No stdout echo or fsync occurs in the timed path.

```sh
cat > "$LAB/stamper.py" <<'PY'
import json, os, sys, termios, time, tty
path = sys.argv[1]
limit = int(sys.argv[2]) if len(sys.argv) > 2 else 60
fd = 0
old = termios.tcgetattr(fd)
logfd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
def record(row):
    data = (json.dumps(row, separators=(',', ':')) + '\n').encode()
    while data:
        data = data[os.write(logfd, data):]
try:
    tty.setraw(fd, termios.TCSANOW)
    record(dict(event='ready', pid=os.getpid(), t=time.monotonic_ns()))
    seq = seen_a = 0
    while seen_a < limit:
        data = os.read(fd, 4096)
        now = time.monotonic_ns()
        if not data:
            break
        for b in data:
            record(dict(event='read', seq=seq, byte=b, t=now))
            seq += 1
            seen_a += b == 97
finally:
    termios.tcsetattr(fd, termios.TCSANOW, old)
    os.close(logfd)
PY
```

Create a **persistent** poster. It calls the same Foundation distributed-notification selector as the Swift tool using `ctypes`, so there is no per-key subprocess or extra package. Foundation/runtime loading, dictionary construction and symbol lookup happen before the timed burst. This selector and dictionary delivery are documented by [Apple](https://developer.apple.com/documentation/foundation/distributednotificationcenter/postnotificationname(_:object:userinfo:deliverimmediately:)). The sender's before/after bracket includes notification-call execution, but not process startup. `deliverImmediately` is not a guarantee that AppKit has already handled the key when the call returns.

```sh
cat > "$LAB/post.py" <<'PY'
import ctypes as c, json, os, sys, time
assert sys.version_info >= (3, 10)
pid, count, path = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
c.CDLL('/System/Library/Frameworks/Foundation.framework/Foundation', mode=c.RTLD_GLOBAL)
objc = c.CDLL('/usr/lib/libobjc.A.dylib')
P = c.c_void_p
objc.objc_getClass.argtypes = [c.c_char_p]
objc.objc_getClass.restype = P
objc.sel_registerName.argtypes = [c.c_char_p]
objc.sel_registerName.restype = P
objc.objc_autoreleasePoolPush.restype = P
objc.objc_autoreleasePoolPop.argtypes = [P]
address = c.cast(objc.objc_msgSend, P).value
def sel(name):
    return objc.sel_registerName(name.encode())
def call(obj, name, result=P, types=(), args=()):
    return c.CFUNCTYPE(result, P, P, *types)(address)(obj, sel(name), *args)
def string(value):
    return call(objc.objc_getClass(b'NSString'), 'stringWithUTF8String:',
                types=(c.c_char_p,), args=(str(value).encode(),))
pool = objc.objc_autoreleasePoolPush()
try:
    center = call(objc.objc_getClass(b'NSDistributedNotificationCenter'), 'defaultCenter')
    fields = {'pid': str(pid), 'kind': 'key', 'key': 'a'}
    keys = (P * len(fields))(*(string(k) for k in fields))
    values = (P * len(fields))(*(string(v) for v in fields.values()))
    info = call(objc.objc_getClass(b'NSDictionary'), 'dictionaryWithObjects:forKeys:count:',
                types=(c.POINTER(P), c.POINTER(P), c.c_ulong),
                args=(values, keys, len(fields)))
    name = string('canvas.dev.input')
    selector = sel('postNotificationName:object:userInfo:deliverImmediately:')
    post = c.CFUNCTYPE(None, P, P, P, P, P, c.c_bool)(address)
    rows = []
    origin = time.monotonic_ns()
    calibration = {'event': 'clock', 'mono_before': time.monotonic_ns(),
                   'wall': time.time_ns(), 'mono_after': time.monotonic_ns()}
    for i in range(count):
        due = origin + i * 100_000_000
        left = (due - time.monotonic_ns()) / 1e9
        if left > 0:
            time.sleep(left)
        before = time.monotonic_ns()
        post(center, selector, name, None, info, True)
        after = time.monotonic_ns()
        rows.append(dict(event='post', seq=i, byte=97, before=before, after=after))
    with open(path, 'w') as f:
        for row in [calibration] + rows:
            f.write(json.dumps(row) + '\n')
finally:
    objc.objc_autoreleasePoolPop(pool)
PY
```

All poster logs are written **after** the burst. An immediate-post interval may slip under scheduling pressure; use actual stamps, not intended deadlines. For timing comparisons, `P − S.before` and `P − S.after` give the before/after-origin range; if handling overlaps the post call, the after-origin difference can be negative. Do not clamp it away.

## Experiment A — replace the lab's attach reader with a stamped Python relay

### Why this exact substitution

**Do not just set `props.command` to Python:** the current app still wraps that command inside `zmx attach` (`Sources/CanvasApp/TerminalTile.swift:133-144`). **Do not put a fake zmx first on PATH:** `Sources/CanvasApp/AppPaths.swift:76-80` prefers `/opt/homebrew/bin/zmx` and `/usr/local/bin/zmx` before PATH. Replacing Homebrew's executable would affect the live app and is forbidden.

Instead, temporarily suspend **only this lab's attach client**, open its existing outer PTY slave as an independent fd, and substitute Python as the sole input reader. The daemon and its original stamper remain untouched and idle. Python forks a fresh inner PTY stamper and relays outer input to it. The Ghostty surface and its master fd stay exactly as they were; no app restart, source edit, binary replacement or debugger is needed.

The relay opens with `O_NOCTTY`, and should be run from a shell **outside the tile under test**. XNU's background-reader job-control check applies when the caller belongs to the terminal's controlling session; an unrelated session is not that background reader ([`bsd/kern/tty.c:3348-3365`](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/tty.c#L3348-L3365)). This is deliberate input substitution, not a passive tap. Check initial readiness before sending any keys.

```sh
cat > "$LAB/relay.py" <<'PY'
import errno, json, os, pathlib, pty, select, signal, subprocess, sys, termios, time, tty
lab, dev, attach = pathlib.Path(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
# Safety: require a zmx attach descendant of the explicitly selected isolated dev process.
rows = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,state=,command='], text=True)
procs = {}
for line in rows.splitlines():
    parts = line.strip().split(None, 3)
    if len(parts) == 4:
        procs[int(parts[0])] = (int(parts[1]), parts[2], parts[3])
assert dev in procs and attach in procs and dev != attach
assert 'zmx' in procs[attach][2] and ' attach ' in (' ' + procs[attach][2] + ' ')
assert 'T' not in procs[attach][1], 'Refuse to resume a client stopped before this experiment'
ancestor = attach
while ancestor in procs and ancestor != dev:
    ancestor = procs[ancestor][0]
assert ancestor == dev, 'Attach is not a descendant of the chosen lab easl PID'
listing = subprocess.check_output(['lsof', '-a', '-p', str(attach), '-d', '0', '-Fn'], text=True)
slaves = [line[1:] for line in listing.splitlines() if line.startswith('n/dev/tty')]
assert len(slaves) == 1, listing
slave = slaves[0]
assert not os.isatty(0) or os.ttyname(0) != slave, 'Run this from outside the tile under test'
outer = inner = child = None
old = None
stopped = False
relay_rows = []
child_output = bytearray()
def interrupt(signum, frame):
    raise KeyboardInterrupt
signal.signal(signal.SIGTERM, interrupt)
try:
    os.kill(attach, signal.SIGSTOP)
    stopped = True
    deadline = time.monotonic() + 3
    while True:
        state = subprocess.check_output(['ps', '-p', str(attach), '-o', 'state='], text=True)
        if 'T' in state:
            break
        if time.monotonic() > deadline:
            raise RuntimeError('Attach did not stop')
        time.sleep(0.01)  # startup only, before measured keys
    outer = os.open(slave, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    old = termios.tcgetattr(outer)
    tty.setraw(outer, termios.TCSANOW)
    termios.tcflush(outer, termios.TCIFLUSH)  # isolated lab input only; start with an empty stream
    child, inner = pty.fork()
    if child == 0:
        try:
            os.close(outer)
            os.execv(sys.executable, [sys.executable, '-u', str(lab / 'stamper.py'),
                                    str(lab / 'a-program.jsonl'), '60'])
        except BaseException:
            os._exit(127)  # never run the parent's resume/cleanup path in this child
    # Child ready means raw mode is installed. Keep startup waits out of the burst.
    deadline = time.monotonic() + 5
    while not (lab / 'a-program.jsonl').exists() or not (lab / 'a-program.jsonl').stat().st_size:
        if time.monotonic() > deadline:
            raise RuntimeError('Inner stamper did not become ready')
        time.sleep(0.01)
    (lab / 'relay.ready').write_text(json.dumps({'relay': os.getpid(), 'attach': attach, 'slave': slave}))
    print('relay ready: ' + slave, flush=True)
    seq = 0
    end = time.monotonic() + 20
    while time.monotonic() < end:
        ready, _, _ = select.select([outer, inner], [], [], max(0, end - time.monotonic()))
        if outer in ready:
            try:
                data = os.read(outer, 4096)
            except BlockingIOError:
                continue
            received = time.monotonic_ns()
            if not data:
                break
            for b in data:
                before = time.monotonic_ns()
                n = os.write(inner, bytes([b]))
                after = time.monotonic_ns()
                assert n == 1
                relay_rows.append(dict(event='relay', seq=seq, byte=b, incoming=received,
                                       before=before, after=after))
                seq += 1
        if inner in ready:
            try:
                output = os.read(inner, 4096)
            except OSError as e:
                if e.errno != errno.EIO:
                    raise
                break
            if not output:
                break
            # Drain inner output without forwarding it into the measured input stream.
            # The stamper emits none; errors should be investigated after the run.
            child_output.extend(output)
finally:
    try:
        if outer is not None:
            try:
                if old is not None:
                    termios.tcsetattr(outer, termios.TCSANOW, old)
            finally:
                os.close(outer)
    finally:
        try:
            if child not in (None, 0):
                try:
                    os.kill(child, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                os.waitpid(child, 0)
            if inner is not None:
                os.close(inner)
        finally:
            if stopped:
                os.kill(attach, signal.SIGCONT)
    (lab / 'a-child-output.bin').write_bytes(child_output)
    with (lab / 'a-relay.jsonl').open('w') as f:
        for row in relay_rows:
            f.write(json.dumps(row) + '\n')
PY
# Use a failure-stopping shell so a readiness failure cannot proceed to the burst.
set -e
# Focus the same lab tile at the probe's known center before substitution; adjust only if its geometry differs.
"$REPO/.build/dev-input" "$EASL_DEV_PID" click 700 400
# Cleanup stops our relay, then resumes only the lab client. It never signals the daemon.
cleanup_relay() {
  if [ -n "${RELAY_PID:-}" ]; then
    kill -TERM "$RELAY_PID" 2>/dev/null || true
    wait "$RELAY_PID" 2>/dev/null || true
  fi
  kill -CONT "$ZMX_ATTACH_PID" 2>/dev/null || true
}
trap cleanup_relay EXIT HUP INT TERM
python3 "$LAB/relay.py" "$LAB" "$EASL_DEV_PID" "$ZMX_ATTACH_PID" &
RELAY_PID=$!
# Wait for relay.ready, not a fixed sleep. Fail if the relay exited or startup takes >8 seconds.
python3 - "$LAB" "$RELAY_PID" <<'PY'
import os, pathlib, sys, time
ready = pathlib.Path(sys.argv[1]) / 'relay.ready'
end = time.monotonic() + 8
while not ready.exists():
    os.kill(int(sys.argv[2]), 0)
    if time.monotonic() > end:
        raise SystemExit('relay startup timeout; resume the lab attach client before retrying')
    time.sleep(0.01)
PY
python3 "$LAB/post.py" "$EASL_DEV_PID" 60 "$LAB/a-posts.jsonl"
wait "$RELAY_PID"
RELAY_PID=
kill -CONT "$ZMX_ATTACH_PID" 2>/dev/null || true
trap - EXIT HUP INT TERM
```

Run these commands in a shell that stops on failures (`set -e`), so a failed readiness check does not proceed to post keys. After abnormal termination the recovery action is **`kill -CONT "$ZMX_ATTACH_PID"`**, never kill the daemon or restart the live app. A SIGKILL cannot execute Python cleanup; the shell trap or explicit recovery must resume the stopped client. Use a fresh scratch directory for each run so stale readiness/log files cannot pass the gate.

Numbers from A, per matched `a` byte:

- `relay.incoming − post.before`: **true notification post → AppKit dispatch → key encoding/mailbox/IO thread → outer PTY → relay read/scheduling**. This is the cheap upstream combined measurement, **not** “Ghostty only.” There is no zmx client/daemon on this measured byte path.
- `relay.before − relay.incoming`: Python relay processing and any time between the read and the next byte's write. For a multi-byte read, later bytes include earlier relay writes.
- `relay.after − relay.before`: inner-master `write` call duration.
- `program.t − relay.before`: inner PTY + program reader scheduling/read, bounded from write entry.
- `program.t − post.before`: new end-to-end path. Keep `key.wait`/`key.handle` separately; only exact per-key `K` would allow `relay.incoming − K` to be called post-keyDown Ghostty/PTY latency.

## Experiment B — zmx alone outside easl, via pty.fork

This creates an outer PTY, runs a **fresh zmx attach client/session** on its slave, and writes `a` to the master. The daemon runs the same stamper on its own inner PTY. It contains no easl, Ghostty, distributed notifications or per-key subprocesses. `ZMX_DIR` confines its sockets and logs to scratch; clearing `ZMX_SESSION` prevents zmx from interpreting this as a switch of the launching agent's existing session ([`src/socket.zig:4-9`](https://github.com/neurosnap/zmx/blob/8bab1f0173b07e79835ea372d749af3dbf0d0842/src/socket.zig#L4-L9), [`src/cfg.zig:45-65`](https://github.com/neurosnap/zmx/blob/8bab1f0173b07e79835ea372d749af3dbf0d0842/src/cfg.zig#L45-L65)). Short session name `s` keeps the Unix socket path beneath macOS's limit. Python's [PTY API](https://docs.python.org/3/library/pty.html#pty.fork) supplies a real controlling terminal, unlike piping stdin.

```sh
cat > "$LAB/zmx-alone.py" <<'PY'
import errno, json, os, pathlib, pty, select, shutil, signal, subprocess, sys, termios, time
lab = pathlib.Path(sys.argv[1])
zmx = shutil.which('zmx')
assert zmx, 'zmx executable missing'
env = dict(os.environ)
for key in ('ZMX_SESSION', 'ZMX_SESSION_PREFIX'):
    env.pop(key, None)
env['ZMX_DIR'] = str(lab / 'z')
env['TMPDIR'] = str(lab)
env['TERM'] = 'xterm-256color'
# No Foundation/ObjC or other higher-level macOS APIs are loaded in this forking process.
child, master = pty.fork()
if child == 0:
    os.execve(zmx, [zmx, 'attach', 's', sys.executable, '-u',
                    str(lab / 'stamper.py'), str(lab / 'b-program.jsonl'), '60'], env)
posts = []
output = bytearray()
def drain(timeout):
    ready, _, _ = select.select([master], [], [], max(0, timeout))
    if ready:
        try:
            data = os.read(master, 65536)
        except OSError as e:
            if e.errno == errno.EIO:
                return False
            raise
        if not data:
            return False
        output.extend(data)
    return True
try:
    # The app is ready only when the inner program has installed raw mode.
    log = lab / 'b-program.jsonl'
    end = time.monotonic() + 8
    while not log.exists() or not log.stat().st_size:
        if time.monotonic() > end:
            raise RuntimeError('Fresh zmx stamper startup timeout')
        if not drain(0.01):
            raise RuntimeError('zmx attach exited before readiness')
    # Also gate on the OUTER attach terminal becoming raw; inner readiness can precede it.
    end = time.monotonic() + 5
    while True:
        attrs = termios.tcgetattr(master)
        if not (attrs[3] & (termios.ICANON | termios.ECHO)) and attrs[6][termios.VTIME] in (0, b'\x00'):
            break
        if time.monotonic() > end:
            raise RuntimeError('Attach did not install outer raw mode')
        if not drain(0.01):
            raise RuntimeError('zmx attach exited before outer raw mode')
    origin = time.monotonic_ns()
    for i in range(60):
        due = origin + i * 100_000_000
        while time.monotonic_ns() < due:
            if not drain((due - time.monotonic_ns()) / 1e9):
                raise RuntimeError('zmx attach exited during burst')
        before = time.monotonic_ns()
        n = os.write(master, b'a')
        after = time.monotonic_ns()
        assert n == 1
        posts.append(dict(event='write', seq=i, byte=97, before=before, after=after))
    # Arrival timestamps are produced inside the program, not when this parent watches its file.
    end = time.monotonic() + 3
    while time.monotonic() < end and drain(min(0.05, end - time.monotonic())):
        pass
finally:
    # This kill uses ONLY the scratch ZMX_DIR and this experiment's session name.
    try:
        subprocess.run([zmx, 'kill', 's'], env=env, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=5)
    finally:
        try:
            os.kill(child, signal.SIGTERM)
        except ProcessLookupError:
            pass
        os.close(master)
        os.waitpid(child, 0)
    (lab / 'b-attach-output.bin').write_bytes(output)
    with (lab / 'b-writes.jsonl').open('w') as f:
        for row in posts:
            f.write(json.dumps(row) + '\n')
PY
python3 "$LAB/zmx-alone.py" "$LAB"
```

`program.t − write.before` means **outer PTY write entry → outer PTY/slave → zmx client read and framing/socket queue → socket → daemon scheduling/PTY queue → inner PTY → program read**. `write.after − write.before` separately measures injection syscall duration. There is no artificial 100 ms read wait in the harness; the 100 ms schedule is only between injections. A plain `script` wrapper can establish a real TTY, but without an injected-byte timestamp it does not improve this measurement; the explicit PTY driver gives the needed clock and controls output draining.

### Analyze both runs without silently truncating lost keys

```sh
python3 - "$LAB" <<'PY'
import json, pathlib, statistics, sys
lab = pathlib.Path(sys.argv[1])
def load(name, event):
    return [r for line in (lab / name).read_text().splitlines()
            if (r := json.loads(line)).get('event') == event and r.get('byte', 97) == 97]
def show(name, values):
    xs = sorted(v / 1e6 for v in values)
    if not xs:
        raise SystemExit(name + ': no samples')
    print(f'{name}: n={len(xs)} median={statistics.median(xs):.3f}ms '
          f'p90={xs[min(len(xs)-1, int(0.9*len(xs)))]:.3f}ms max={xs[-1]:.3f}ms')
a, r, p = load('a-posts.jsonl', 'post'), load('a-relay.jsonl', 'relay'), load('a-program.jsonl', 'read')
assert len(a) == len(r) == len(p) == 60, ('A count mismatch', len(a), len(r), len(p))
show('A notification-post to relay read', [y['incoming']-x['before'] for x,y in zip(a,r)])
show('A relay processing', [x['before']-x['incoming'] for x in r])
show('A relay write syscall', [x['after']-x['before'] for x in r])
show('A relay write-entry to program read', [y['t']-x['before'] for x,y in zip(r,p)])
show('A post to program read', [y['t']-x['before'] for x,y in zip(a,p)])
show('A notification call bracket', [x['after']-x['before'] for x in a])
b, q = load('b-writes.jsonl', 'write'), load('b-program.jsonl', 'read')
assert len(b) == len(q) == 60, ('B count mismatch', len(b), len(q))
show('B zmx-alone write-entry to program read', [y['t']-x['before'] for x,y in zip(b,q)])
show('B outer write syscall', [x['after']-x['before'] for x in b])
PY
```

Alignment here is ordinal because every injected key is exactly ASCII `a`, never terminal paste or a Kitty-enhanced sequence. Stop typing into the measured tile while the run is active; retain complete raw JSONL and non-`a` bytes for diagnosis. If counts disagree, fail the run rather than using `zip` to hide loss. A single returned read containing several `a`s is legitimate evidence of scheduling/batching and gets the same read timestamp for each byte.

## How to interpret the split

1. **A small, B small**: the original pre-launch→program number is not evidence of a long post-keyDown write path. Re-run the ordinary zmx-backed lab with `post.py` (same focused tile; relay stopped/resumed) and the original stamper, while keeping sender and program stamps. The drop relative to the old measurement is evidence for upstream launcher/replay overhead; do not pretend a cross-run median difference is exact per-sample subtraction.
2. **A large, B small**: delay is before the substituted reader — notification/AppKit scheduling, Ghostty IO scheduling, or outer PTY/reader scheduling. Exact `K` plus easl write/read trace disambiguates; aggregate key metrics alone cannot remove notification delivery.
3. **A small, B large**: the zmx/second-PTY path is implicated independently of easl. Trace `A,C,D,W,P` to distinguish client readiness, socket/daemon scheduling, daemon queue or program read. The source provides no fixed timer explanation.
4. **Both large**: check host scheduling, background QoS/App Nap, or measurement artifacts common to both; no new workload or stress run is needed to reach that conclusion. Exact syscall intervals decide whether transport or delayed scheduling dominates.
5. Do **not** subtract independently measured medians and label the result exact kernel/PTy latency. These experiments alter topology and scheduling; they locate the dominant region. The shepherd capture, with a usable `K` probe if needed, provides a same-run per-key hop decomposition.

For subsequent verification, Tim/main should run A and B in fresh scratch directories or one fresh directory containing these distinct A/B filenames, check the 60/60/60 and 60/60 counts, inspect anomalous child output, then request the 20-second shepherd capture if any true-post residual remains large. Everything started by either snippet is stopped/reaped; A resumes only the client it stopped, and B kills only its scratch-isolated session.
