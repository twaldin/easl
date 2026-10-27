# Note math

Users read inline and display LaTeX in native notes. Unsupported formulas render as source. Over-limit formulas are rejected before native typesetting.

## Sub-features

- `note-math-inline` typesets `$e^{i\pi}+1=0$` within prose.
- `note-math-display` typesets a centered `$$...$$` paragraph.
- `note-math-fallback` shows source when a formula exceeds the native limits or fails to parse.
- `note-math-literal` leaves code fences and escaped dollars literal.

## How to get to it (user POV)

Open a note containing Markdown with math delimiters. Create a fixture through `object.create`, then use Command-P to find its heading. API creation seeds content; it does not qualify native note editing.

## Driving it with dev.sh

Preconditions: follow the skill's Launch and Doctor sections. Run this journey on a local board and a remote board served by guest-local scratch easld. Use the corresponding socket and an explicit board ID for fixture calls.

1. Create a note with this Markdown:

	````text
	# Native math and ordinary code

	Inline $e^{i\pi}+1=0$.

	$$\sum_{i=1}^{n} i=\frac{n(n+1)}{2}$$

	```mermaid
	graph TD
	  A[Start] --> B[Done]
	```

	Literal code: `$x^2$`. After the code fence.

	```text
	$x^2$ and $$y$$ stay literal here.
	```

	Broken $\notarealcommand{x}$ here.

	Escaped \$x\$ stays prose.
	````

2. Navigate to the heading through Command-P, then use Command-0 to show actual size. Capture the note by exact PID and window ID. Require typeset inline and display formulas, literal inline and fenced math, escaped `$x$`, source fallback for the unsupported command, and trailing prose. Verify [Mermaid](note-mermaid.md) separately; do not require its fence to stay code.
3. Create a second note with a display formula whose source is `\frac{1}{` repeated 32 times, followed by `x`, then 32 closing braces. Capture the visible source fallback and trailing text. Read back `props.markdown` and compare it byte-for-byte to the fixture.
4. Reopen the board and capture both notes. Require unchanged Markdown. On the remote board, compare the host's persisted note props as well as the viewer's pixels.

## Gotchas

- Native math accepts at most 2,048 UTF-8 bytes, 256 structural markers, 16 simultaneous parser frames, and 128 work units. These are separate limits; a short deeply nested formula can fall back.
- Delimiters follow currency-aware rules. A code fence is not a math entry point.
- HTML math uses KaTeX, not SwiftMath. Exercise it separately through an HTML tile with `$...$` and `$$...$$` content. Native fallback proof does not qualify HTML rendering.
- Source entry points are `Sources/CanvasCore/NoteMath.swift` and `Sources/CanvasCore/NoteRenderer.swift`. The retained #184 feature smoke supplies the Euler and sum fixtures; do not reuse its captures as evidence of another candidate.
