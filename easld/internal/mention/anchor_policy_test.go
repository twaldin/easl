package mention

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/twaldin/easl/easld/internal/measure"
)

func TestRefusedFencesAreNotAnchored(t *testing.T) {
	board := t.TempDir()
	outside := filepath.Join(t.TempDir(), "outside.rs")
	const marker = "DO_NOT_SHOW_OUTSIDE_HOST_68c1"
	if err := os.WriteFile(outside, []byte(marker+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	writeFile(t, board, "inside.rs", "visible line\n")
	reading := measure.LinkReading{Root: board, Board: board}
	refused := "Authored prose\n\n```rs file=" + outside + "#L1\n```\n"
	if got := AnchoringRanges(refused, reading); got != refused {
		t.Fatalf("anchored a refused fence: %q", got)
	}
	allowed := "```rs file=inside.rs#L1\n```\n"
	if got := AnchoringRanges(allowed, reading); got != "```rs file=inside.rs#L1 anchor=\"visible line\"\n```\n" {
		t.Fatalf("allowed anchor %q", got)
	}
	status := NoteFences(refused+"\n"+allowed, reading)
	if len(status) != 2 {
		t.Fatalf("fences %v", status)
	}
	first := status[0].(map[string]any)
	if first["state"] != "stale" || first["reason"] != "path refused" || first["range"] != nil {
		t.Fatalf("refused status %v", first)
	}
	second := status[1].(map[string]any)
	if second["state"] != "live" || second["reason"] != nil {
		t.Fatalf("allowed status %v", second)
	}
}

func TestScrubRefusedAnchorsPreservesAuthoredMarkdownBytes(t *testing.T) {
	root := t.TempDir()
	writeFile(t, root, "inside.rs", "inside anchor\n")
	reading := measure.LinkReading{Root: root, Board: root}
	for _, test := range []struct {
		name, markdown, want string
	}{
		{
			"nested list and blockquote with CRLF",
			"> 1. - ~~~rs file=../outside.rs#L1 anchor=\"legacy\"  \r\n>      authored anchor=\"body\"\r\n>      ~~~\r\n",
			"> 1. - ~~~rs file=../outside.rs#L1   \r\n>      authored anchor=\"body\"\r\n>      ~~~\r\n",
		},
		{
			"ordered list parenthesis delimiter",
			"1) ~~~rs file=../outside.rs#L1 anchor=legacy\n   authored body\n   ~~~\n",
			"1) ~~~rs file=../outside.rs#L1 \n   authored body\n   ~~~\n",
		},
		{
			"entities and duplicate attributes",
			"```rs file=..&#47;outside.rs#L1 &#97;nchor=&quot;first &amp; second&quot;\tanchor='last' caption=\"keep &amp; bytes\" \nbody\n```\n",
			"```rs file=..&#47;outside.rs#L1 \t caption=\"keep &amp; bytes\" \nbody\n```\n",
		},
		{
			"CommonMark escaped quotes and escaped attribute key",
			"~~~rs file=../outside.rs#L1 anchor\\=\\\"legacy\\\" keep='anchor=\"authored\"'\n~~~",
			"~~~rs file=../outside.rs#L1  keep='anchor=\"authored\"'\n~~~",
		},
		{
			"escaped quote inside an anchor",
			`~~~rs file=../outside.rs#L1 anchor="one \\" two" language=rs` + "\n~~~\n",
			"~~~rs file=../outside.rs#L1  language=rs\n~~~\n",
		},
		{
			"empty duplicate does not hide metadata",
			"```rs file=../outside.rs#L1 anchor=legacy anchor=\"\"\n```\n",
			"```rs file=../outside.rs#L1  \n```\n",
		},
		{
			"authored prose body and caption",
			"prose anchor=\"keep\"\n\n````rs file=../outside.rs#L1 anchor=\"legacy\" caption='anchor=\"keep caption\"'\n```rs file=../outside.rs#L1 anchor=\"keep body\"\n```\n````\n",
			"prose anchor=\"keep\"\n\n````rs file=../outside.rs#L1  caption='anchor=\"keep caption\"'\n```rs file=../outside.rs#L1 anchor=\"keep body\"\n```\n````\n",
		},
		{
			"allowed stale and missing anchors remain",
			"```rs file=inside.rs#L99 anchor=\"stale anchor\"\n```\n\n```rs file=missing.rs#L1 anchor=\"missing anchor\"\n```\n",
			"```rs file=inside.rs#L99 anchor=\"stale anchor\"\n```\n\n```rs file=missing.rs#L1 anchor=\"missing anchor\"\n```\n",
		},
		{
			"free and indented code are authored",
			"```rs anchor=\"keep free\"\n```\n\n    ```rs file=../outside.rs anchor=\"keep indented\"\n",
			"```rs anchor=\"keep free\"\n```\n\n    ```rs file=../outside.rs anchor=\"keep indented\"\n",
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			got := ScrubRefusedAnchors(test.markdown, reading)
			if got != test.want {
				t.Fatalf("scrub = %q, want %q", got, test.want)
			}
			if again := ScrubRefusedAnchors(got, reading); again != test.want {
				t.Fatalf("second scrub = %q, want %q", again, test.want)
			}
		})
	}
}
