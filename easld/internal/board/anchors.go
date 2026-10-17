package board

import (
	"github.com/twaldin/easl/easld/internal/measure"
	"github.com/twaldin/easl/easld/internal/mention"
	"github.com/twaldin/easl/easld/internal/model"
	"github.com/twaldin/easl/easld/internal/store"
)

// scrubSnapshotAnchors normalizes metadata before a live board or its history exists.
func scrubSnapshotAnchors(snapshot *store.Snapshot) bool {
	changed := false
	for _, object := range snapshot.Objects {
		switch object.Type {
		case model.Note:
			markdown, ok := object.Props["markdown"].(string)
			if !ok {
				continue
			}
			clean := mention.ScrubRefusedAnchors(markdown, measure.ReadingFor(object.Props, snapshot.Root))
			if clean != markdown {
				object.Props["markdown"] = clean
				changed = true
			}
		case model.Code:
			if _, present := object.Props["anchor"]; !present {
				continue
			}
			path, ok := object.Props["path"].(string)
			if !ok {
				continue
			}
			fence := measure.Fence{Path: &path}
			if commit, ok := object.Props["pinnedCommit"].(string); ok {
				fence.Commit = &commit
			}
			reading := measure.LinkReading{Root: snapshot.Root, Board: snapshot.Root}
			if measure.RefOf(object.Props) != "" {
				reading = measure.ReadingFor(object.Props, snapshot.Root)
			}
			if reading.RefusesFence(fence) {
				delete(object.Props, "anchor")
				changed = true
			}
		}
	}
	return changed
}
