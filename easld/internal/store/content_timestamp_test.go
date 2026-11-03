package store

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/twaldin/easl/easld/internal/model"
)

func TestContentUpdatedAtIsAnOptionalFormatThreeTimestamp(t *testing.T) {
	at := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	format := Format
	o := model.Object{ID: "obj_note", Type: model.Note, Rev: 1, CreatedBy: model.Actor{Kind: "user"}, CreatedAt: at, UpdatedAt: at.Add(time.Hour), Props: map[string]any{"markdown": "saved"}}
	for _, tc := range []struct {
		name    string
		present bool
		value   any
		valid   bool
	}{
		{"absent", false, nil, true},
		{"null", true, nil, true},
		{"timestamp", true, model.FileTime(at), true},
		{"invalid timestamp", true, "yesterday", false},
		{"numeric API date in file", true, 1.0, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			raw := (&Snapshot{Format: &format, ID: "brd_content", Root: "/r", Objects: []model.Object{o}}).JSON()
			object := raw["objects"].([]any)[0].(map[string]any)
			if tc.present {
				object["contentUpdatedAt"] = tc.value
			}
			data, err := json.Marshal(raw)
			if err != nil {
				t.Fatal(err)
			}
			snapshot, err := DecodeSnapshot(data)
			if !tc.valid {
				if err == nil {
					t.Fatal("invalid content timestamp was accepted")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			want := o.UpdatedAt
			if *snapshot.Format != 3 || !snapshot.Objects[0].ContentTime().Equal(want) {
				t.Fatalf("optional timestamp did not retain format and effective age: %+v", snapshot)
			}
		})
	}
}

func TestContentRevisionOptionalStorageValidation(t *testing.T) {
	at := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	format := Format
	o := model.Object{ID: "obj_note", Type: model.Note, Rev: 2, CreatedBy: model.Actor{Kind: "user"}, CreatedAt: at, UpdatedAt: at.Add(time.Hour), ContentUpdatedAt: at, Props: map[string]any{"markdown": "saved"}}
	for _, tc := range []struct {
		name    string
		marker  any
		valid   bool
		trusted bool
	}{
		{"null", nil, true, false},
		{"matching", 2.0, true, true},
		{"mismatch", 1.0, true, false},
		{"future", 3.0, true, false},
		{"zero", 0.0, true, false},
		{"negative", -1.0, true, false},
		{"fraction", 1.5, false, false},
		{"string", "2", false, false},
		{"boolean", true, false, false},
		{"overflow", 1e30, false, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			raw := (&Snapshot{Format: &format, ID: "brd_content", Root: "/r", Objects: []model.Object{o}}).JSON()
			raw["objects"].([]any)[0].(map[string]any)["contentRev"] = tc.marker
			data, err := json.Marshal(raw)
			if err != nil {
				t.Fatal(err)
			}
			snapshot, err := DecodeSnapshot(data)
			if !tc.valid {
				if err == nil {
					t.Fatal("invalid content revision was accepted")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			want := o.UpdatedAt
			if tc.trusted {
				want = at
			}
			if *snapshot.Format != 3 || !snapshot.Objects[0].ContentTime().Equal(want) {
				t.Fatalf("effective content age = %+v, want %s", snapshot.Objects[0], want)
			}
		})
	}
}
