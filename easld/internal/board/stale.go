package board

import (
	"strings"
	"time"

	"github.com/twaldin/easl/easld/internal/mention"
	"github.com/twaldin/easl/easld/internal/model"
)

func (b *Board) Stale(now time.Time, olderThan time.Duration, exited map[string]bool) []any {
	objects := []any{}
	cutoff := now.Add(-olderThan)
	for _, id := range b.sortedIDs() {
		o := b.objects[id]
		reasons := []any{}
		if o.CreatedBy.Kind == "agent" && b.objects[o.CreatedBy.Tile].Type != model.Terminal {
			reasons = append(reasons, "creator-gone")
		}
		if o.Expires != nil && !o.Expires.After(now) {
			reasons = append(reasons, "expired")
		}
		if o.UpdatedAt.Before(cutoff) {
			reasons = append(reasons, "untouched")
		}
		if o.Type == model.Terminal && exited[id] {
			reasons = append(reasons, "exited")
		}
		if len(reasons) == 0 {
			continue
		}
		entry := map[string]any{
			"id": id, "type": string(o.Type), "title": staleTitle(o),
			"createdBy": o.CreatedBy.JSON(), "updatedAt": model.APITime(o.UpdatedAt), "reasons": reasons,
		}
		if key, ok := o.Props["key"].(string); ok {
			entry["key"] = key
		}
		objects = append(objects, entry)
	}
	return objects
}

func staleTitle(o model.Object) string {
	for _, key := range []string{"title", "caption"} {
		if text, ok := o.Props[key].(string); ok && text != "" {
			first, _, _ := strings.Cut(text, "\n")
			return first
		}
	}
	title := mention.Title(o)
	if title == "" {
		for _, key := range []string{"markdown", "question", "text", "label", "path", "url", "name"} {
			if text, ok := o.Props[key].(string); ok && text != "" {
				title = text
				break
			}
		}
	}
	first, _, _ := strings.Cut(title, "\n")
	return first
}
