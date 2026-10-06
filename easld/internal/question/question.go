// Package question ports QuestionSpec (Sources/CanvasCore/Question.swift): the `question` object
// type, a question an agent asks the user on the board (schema QuestionProps). Lifecycle: open →
// answered | cancelled | expired, each final; archiving is not a status (`archived: true` hides a
// closed question's tile). Validation (Problem) is the one rule both servers apply, messages
// included; the Board's writes of questions (QuestionToCreate, QuestionUpdate, expiry, the
// hand-off of an answer) are in package board. Props stay the generic JSON forms.
package question

import (
	"fmt"
	"math"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/twaldin/easl/easld/internal/model"
)

// Status is QuestionSpec.Status.
type Status string

const (
	Open      Status = "open"
	Answered  Status = "answered"
	Cancelled Status = "cancelled"
	Expired   Status = "expired"
)

func parseStatus(s string) (Status, bool) {
	switch st := Status(s); st {
	case Open, Answered, Cancelled, Expired:
		return st, true
	}
	return "", false
}

// StatusOf is QuestionSpec.status(of:): `props.status`; a question without a status it knows is open.
func StatusOf(props map[string]any) Status {
	if s, ok := props["status"].(string); ok {
		if st, ok := parseStatus(s); ok {
			return st
		}
	}
	return Open
}

// Option is QuestionSpec.Option.
type Option struct {
	ID, Label string
	Why       *string
}

// Context is QuestionSpec.Context: an object (an id), a URL, or a path with optional lines.
type Context struct {
	Kind  string // "object", "url" or "path"
	Value string
	Lines *model.LineRange
}

// Label is how a context reads in a mention: the id, the URL, `path:12-20`.
func (c Context) Label() string {
	if c.Kind == "path" && c.Lines != nil {
		if c.Lines.Start == c.Lines.End {
			return c.Value + ":" + strconv.Itoa(c.Lines.Start)
		}
		return c.Value + ":" + strconv.Itoa(c.Lines.Start) + "-" + strconv.Itoa(c.Lines.End)
	}
	return c.Value
}

// Asker is QuestionSpec.Asker: a terminal on the board (Tile), or a name (an agent elsewhere, a
// script), optionally on a host.
type Asker struct {
	Tile, Name, Host *string
}

// Label is `cos@mini`, `cos`, `terminal obj_…`, or `cos@mini (terminal obj_…)`.
func (a Asker) Label() string {
	var named *string
	if a.Name != nil {
		n := *a.Name
		if a.Host != nil {
			n += "@" + *a.Host
		}
		named = &n
	}
	switch {
	case named != nil && a.Tile != nil:
		return *named + " (terminal " + *a.Tile + ")"
	case named != nil:
		return *named
	case a.Tile != nil:
		return "terminal " + *a.Tile
	}
	return "someone"
}

// Answer is QuestionSpec.Answer (`at` is read from the props where a mention shows it).
type Answer struct {
	Option, Note *string
	By           *model.Actor
}

// Spec is QuestionSpec: a question's props as stored (validated on the way in); anything
// unreadable is left out.
type Spec struct {
	Question    string
	Options     []Option
	Recommended *string
	Context     []Context
	Asker       *Asker
	Status      Status
	ExpiresAt   *time.Time
	Answer      *Answer
	Archived    bool
}

func optString(m map[string]any, key string) *string {
	if s, ok := m[key].(string); ok {
		return &s
	}
	return nil
}

// Read is QuestionSpec.init(_ props:).
func Read(props map[string]any) Spec {
	spec := Spec{Status: StatusOf(props)}
	spec.Question, _ = props["question"].(string)
	options, _ := props["options"].([]any)
	for _, o := range options {
		fields, _ := o.(map[string]any)
		id, ok1 := fields["id"].(string)
		label, ok2 := fields["label"].(string)
		if ok1 && ok2 {
			spec.Options = append(spec.Options, Option{ID: id, Label: label, Why: optString(fields, "why")})
		}
	}
	spec.Recommended = optString(props, "recommended")
	items, _ := props["context"].([]any)
	for _, item := range items {
		if c, ok := contextOf(item); ok {
			spec.Context = append(spec.Context, c)
		}
	}
	if asker, ok := props["asker"].(map[string]any); ok {
		spec.Asker = &Asker{Tile: optString(asker, "tile"), Name: optString(asker, "name"), Host: optString(asker, "host")}
	}
	if s, ok := props["expiresAt"].(string); ok {
		if t, ok := Date(s); ok {
			spec.ExpiresAt = &t
		}
	}
	if answer, ok := props["answer"].(map[string]any); ok {
		spec.Answer = &Answer{Option: optString(answer, "option"), Note: optString(answer, "note")}
		if by, ok := decodeActor(answer["by"]); ok {
			spec.Answer.By = &by
		}
	}
	spec.Archived = props["archived"] == true
	return spec
}

// decodeActor is `try? decode(Actor.self)`: {kind, tile?}; any kind but "agent" is the user.
func decodeActor(v any) (model.Actor, bool) {
	m, ok := v.(map[string]any)
	if !ok {
		return model.Actor{}, false
	}
	kind, ok := m["kind"].(string)
	if !ok {
		return model.Actor{}, false
	}
	if kind == "agent" {
		tile, ok := m["tile"].(string)
		return model.Actor{Kind: "agent", Tile: tile}, ok
	}
	return model.Actor{Kind: "user"}, true
}

// Option is QuestionSpec.option(_:): the option with this id.
func (s Spec) Option(id *string) *Option {
	if id == nil {
		return nil
	}
	for i := range s.Options {
		if s.Options[i].ID == *id {
			return &s.Options[i]
		}
	}
	return nil
}

// --- validation ---

// What a closed question still takes.
var closedKeys = map[string]bool{"archived": true, "key": true, "zoom": true}

const (
	optionsShape = "an array of {id, label, why?}"
	answerShape  = "an answered question needs answer: {option, note?} or {note}"
)

var (
	optionKeys  = map[string]bool{"id": true, "label": true, "why": true}
	contextKeys = map[string]bool{"object": true, "url": true, "path": true, "lines": true}
	askerKeys   = map[string]bool{"tile": true, "name": true, "host": true}
	idPattern   = regexp.MustCompile(`^[a-z]+_[0-9A-Za-z]+$`)
)

// Creating is QuestionSpec.creating: `object.create` props of a question as stored: `status`
// open and, when the call has a caller ("" for none) and names no asker, the calling terminal as
// `asker`.
func Creating(props map[string]any, caller string) map[string]any {
	fields, _ := model.Clone(props).(map[string]any)
	if fields == nil {
		fields = map[string]any{}
	}
	if fields["status"] == nil {
		fields["status"] = string(Open)
	}
	if fields["asker"] == nil && caller != "" {
		fields["asker"] = map[string]any{"tile": caller}
	}
	return fields
}

// Problem is QuestionSpec.problem: why patch can't be written, or ok false when it can. On
// create (before nil) the props as Creating filled them, on update the patch of before, judged
// merged. The rules run in order and the first that fails is the message. patch is the call's
// `props` as received (any JSON value).
func Problem(patch any, before *model.Object) (message string, bad bool) {
	if before != nil {
		old := string(Open)
		if s, ok := before.Props["status"].(string); ok {
			old = s
		}
		if fields, ok := patch.(map[string]any); ok && old != string(Open) {
			for _, key := range sortedKeys(fields) {
				if closedKeys[key] {
					continue
				}
				value := fields[key]
				stored, present := before.Props[key]
				var same bool
				if value == nil {
					same = !present
				} else {
					same = present && model.Equal(stored, value)
				}
				if !same {
					return fmt.Sprintf("question %s is %s: only archived can change", before.ID, old), true
				}
			}
		}
	}
	var merged any = patch
	if before != nil {
		merged = model.Merge(before.Props, patch)
	}
	props, _ := merged.(map[string]any)
	given := func(key string) (any, bool) {
		v := props[key]
		return v, v != nil
	}
	text, _ := given("question")
	if question, ok := text.(string); !ok || trimmed(question) == "" {
		return "a question needs props.question, a non-empty string", true
	}
	list, _ := given("options")
	options, ok := list.([]any)
	if !ok {
		return "a question needs props.options, " + optionsShape, true
	}
	var ids []string
	for index, option := range options {
		fields, ok := option.(map[string]any)
		if !ok {
			return fmt.Sprintf("options[%d] must be {id, label, why?}", index), true
		}
		for _, key := range sortedKeys(fields) {
			if !optionKeys[key] {
				return fmt.Sprintf("options[%d] has unknown key \"%s\" (an option is {id, label, why?})", index, key), true
			}
		}
		id, ok := fields["id"].(string)
		if !ok || id == "" {
			return fmt.Sprintf("options[%d] needs an id, a non-empty string", index), true
		}
		label, ok := fields["label"].(string)
		if !ok || trimmed(label) == "" {
			return fmt.Sprintf("options[%d] needs a label, a non-empty string", index), true
		}
		if why, present := fields["why"]; present && why != nil {
			if _, isString := why.(string); !isString {
				return fmt.Sprintf("options[%d].why must be a string", index), true
			}
		}
		for _, earlier := range ids {
			if earlier == id {
				return fmt.Sprintf("option id \"%s\" is used twice", id), true
			}
		}
		ids = append(ids, id)
	}
	idList := "none"
	if len(ids) > 0 {
		idList = strings.Join(ids, ", ")
	}
	isOption := func(id string) bool {
		for _, known := range ids {
			if known == id {
				return true
			}
		}
		return false
	}
	if recommended, ok := given("recommended"); ok {
		id, isString := recommended.(string)
		if !isString {
			return "recommended must be an option id (" + idList + ")", true
		}
		if !isOption(id) {
			return fmt.Sprintf("recommended \"%s\" is not an option id (%s)", id, idList), true
		}
	}
	if context, ok := given("context"); ok {
		items, isArray := context.([]any)
		if !isArray {
			return "props.context must be an array of {object}, {url}, or {path, lines?}", true
		}
		for index, item := range items {
			if _, valid := contextOf(item); !valid {
				return fmt.Sprintf("context[%d] must be {object: \"obj_…\"}, {url: \"…\"}, or {path: \"…\", lines?: {start, end}}", index), true
			}
		}
	}
	asker, ok := given("asker")
	if !ok {
		return "a question needs props.asker, {name, host?}, when no terminal asks it (no caller)", true
	}
	if !validAsker(asker) {
		return "asker must be {tile: \"obj_…\"} or {name, host?}", true
	}
	statusValue, _ := given("status")
	statusText, _ := statusValue.(string)
	status, ok := parseStatus(statusText)
	if !ok {
		return "status must be open, answered, cancelled, or expired", true
	}
	if before == nil && status != Open {
		return fmt.Sprintf("a question is created open, not %s", status), true
	}
	if expiresAt, ok := given("expiresAt"); ok {
		text, isString := expiresAt.(string)
		if _, parsed := Date(text); !isString || !parsed {
			return "expiresAt must be an ISO 8601 date-time, e.g. 2026-10-05T17:00:00Z", true
		}
	}
	answerValue, hasAnswer := given("answer")
	if status == Answered {
		answer, isObject := answerValue.(map[string]any)
		if !hasAnswer || !isObject {
			return answerShape, true
		}
		picked := false
		if option := answer["option"]; option != nil {
			id, isString := option.(string)
			if !isString {
				return "answer.option must be an option id (" + idList + ")", true
			}
			if !isOption(id) {
				return fmt.Sprintf("answer.option \"%s\" is not an option id (%s)", id, idList), true
			}
			picked = true
		}
		noted := false
		if note := answer["note"]; note != nil {
			text, isString := note.(string)
			if !isString {
				return "answer.note must be a string", true
			}
			noted = trimmed(text) != ""
		}
		if !picked && !noted {
			return answerShape, true
		}
	} else if hasAnswer {
		return "answer goes with status answered", true
	}
	if archived, ok := given("archived"); ok {
		flag, isBool := archived.(bool)
		if !isBool {
			return "archived must be true or false", true
		}
		if flag && status == Open {
			return "an open question can't be archived: answer or cancel it first", true
		}
	}
	return "", false
}

func sortedKeys(m map[string]any) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// trimmed is trimmingCharacters(in: .whitespacesAndNewlines).
func trimmed(text string) string {
	return strings.TrimFunc(text, func(r rune) bool {
		switch r {
		case '\t', '\n', '\v', '\f', '\r', ' ', 0x85, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
			return true
		}
		return r >= 0x2000 && r <= 0x200A
	})
}

// isID is `range(of: "^[a-z]+_[0-9A-Za-z]+$", options: .regularExpression)`: ICU's `$` also
// matches before a line terminator that ends the text.
func isID(v any) bool {
	s, ok := v.(string)
	if !ok {
		return false
	}
	switch {
	case strings.HasSuffix(s, "\r\n"):
		s = strings.TrimSuffix(s, "\r\n")
	default:
		for _, terminator := range []string{"\n", "\v", "\f", "\r", "\u0085", "\u2028", "\u2029"} {
			if strings.HasSuffix(s, terminator) {
				s = strings.TrimSuffix(s, terminator)
				break
			}
		}
	}
	return idPattern.MatchString(s)
}

func validAsker(asker any) bool {
	fields, ok := asker.(map[string]any)
	if !ok {
		return false
	}
	for key := range fields {
		if !askerKeys[key] {
			return false
		}
	}
	if tile, present := fields["tile"]; present && !isID(tile) {
		return false
	}
	if name, present := fields["name"]; present {
		if s, isString := name.(string); !isString || s == "" {
			return false
		}
	}
	if host, present := fields["host"]; present {
		if _, isString := host.(string); !isString {
			return false
		}
	}
	_, hasTile := fields["tile"]
	_, hasName := fields["name"]
	return hasTile || hasName
}

// contextOf is QuestionSpec.context(_:): one `context` item: exactly one of `object` (an id),
// `url`, or `path` (with `lines` only beside a path); ok false for anything else.
func contextOf(item any) (Context, bool) {
	fields, ok := item.(map[string]any)
	if !ok {
		return Context{}, false
	}
	for key := range fields {
		if !contextKeys[key] {
			return Context{}, false
		}
	}
	var kinds []string
	for _, kind := range []string{"object", "url", "path"} {
		if _, present := fields[kind]; present {
			kinds = append(kinds, kind)
		}
	}
	if len(kinds) != 1 {
		return Context{}, false
	}
	_, hasLines := fields["lines"]
	if hasLines && kinds[0] != "path" {
		return Context{}, false
	}
	switch kinds[0] {
	case "object":
		id, _ := fields["object"].(string)
		if !isID(fields["object"]) {
			return Context{}, false
		}
		return Context{Kind: "object", Value: id}, true
	case "url":
		url, ok := fields["url"].(string)
		if !ok || url == "" {
			return Context{}, false
		}
		return Context{Kind: "url", Value: url}, true
	}
	path, ok := fields["path"].(string)
	if !ok || path == "" {
		return Context{}, false
	}
	if !hasLines {
		return Context{Kind: "path", Value: path}, true
	}
	lines, ok := fields["lines"].(map[string]any)
	if !ok || len(lines) != 2 {
		return Context{}, false
	}
	start, ok1 := lines["start"].(float64)
	end, ok2 := lines["end"].(float64)
	if !ok1 || !ok2 || start != math.Round(start) || end != math.Round(end) || start < 1 || end < start || end > float64(math.MaxInt64/2) {
		return Context{}, false
	}
	return Context{Kind: "path", Value: path, Lines: &model.LineRange{Start: int(start), End: int(end)}}, true
}

// --- dates ---

// Date is QuestionSpec.date: an RFC 3339 date-time (`2026-10-05T17:00:00Z`, an offset,
// fractional seconds); ok false otherwise.
func Date(text string) (time.Time, bool) {
	t, err := time.Parse(time.RFC3339, text)
	return t, err == nil
}

// Stamp is QuestionSpec.stamp: how easl writes a moment (`answer.at`): UTC, whole seconds.
func Stamp(t time.Time) string { return model.FileTime(t) }

// --- size ---

// A new question tile's width, and the rows its height is counted in: the title bar, the
// question, one row per option, the context links, the note field and the footer while it is
// open; once closed, the question over its answer (and note) and who answered when.
const (
	Width      = 460.0
	OpenBase   = 194.0
	OptionRow  = 50.0
	ContextRow = 30.0
	ClosedBase = 148.0
	NoteRow    = 40.0
)

// Size is QuestionSpec.size: the tile's frame size at 100% for these props (`object.create`
// without a frame, `object.measure`, `size: fit`): counted from the props, not measured, so every
// client and server agrees. Text that needs more scrolls inside the tile.
func Size(props map[string]any) (w, h float64) {
	if StatusOf(props) == Open {
		options, _ := props["options"].([]any)
		context := 0.0
		if items, ok := props["context"].([]any); ok && len(items) > 0 {
			context = ContextRow
		}
		return Width, OpenBase + OptionRow*float64(len(options)) + context
	}
	noted := false
	if answer, ok := props["answer"].(map[string]any); ok {
		if note, ok := answer["note"].(string); ok {
			noted = trimmed(note) != ""
		}
	}
	h = ClosedBase
	if noted {
		h += NoteRow
	}
	return Width, h
}

// --- mentions ---

// MentionLines is QuestionSpec.mentionLines: what a mention of the question tells an agent,
// below its `[n] question obj_… "…"` line: the whole question, who asked and where it stands, the
// options (the recommended one marked), its context, and the answer.
func MentionLines(props map[string]any) []string {
	spec := Read(props)
	oneLine := func(s string) string { return strings.ReplaceAll(s, "\n", "\\n") }
	lines := []string{"    question: " + oneLine(spec.Question)}
	asker := "someone"
	if spec.Asker != nil {
		asker = spec.Asker.Label()
	}
	state := []string{"asked by " + asker, string(spec.Status)}
	if spec.Archived {
		state = append(state, "archived")
	}
	if expires, ok := props["expiresAt"].(string); ok && spec.Status == Open {
		state = append(state, "expires "+expires)
	}
	lines = append(lines, "    "+strings.Join(state, " · "))
	for _, option := range spec.Options {
		recommended := ""
		if spec.Recommended != nil && option.ID == *spec.Recommended {
			recommended = " (recommended)"
		}
		why := ""
		if option.Why != nil {
			why = ": " + *option.Why
		}
		lines = append(lines, "    ["+option.ID+"] "+option.Label+recommended+why)
	}
	if len(spec.Context) > 0 {
		labels := make([]string, len(spec.Context))
		for i, c := range spec.Context {
			labels[i] = c.Label()
		}
		lines = append(lines, "    context: "+strings.Join(labels, ", "))
	}
	if spec.Status == Answered && spec.Answer != nil {
		answer := spec.Answer
		var parts []string
		if answer.Option != nil {
			part := "[" + *answer.Option + "]"
			if option := spec.Option(answer.Option); option != nil {
				part += " " + option.Label
			}
			parts = append(parts, part)
		}
		if answer.Note != nil && trimmed(*answer.Note) != "" {
			parts = append(parts, "note: \""+oneLine(*answer.Note)+"\"")
		}
		at := ""
		if stored, ok := props["answer"].(map[string]any); ok {
			if text, ok := stored["at"].(string); ok {
				at = " at " + text
			}
		}
		switch {
		case answer.By != nil && answer.By.Kind == "agent":
			parts = append(parts, "by terminal "+answer.By.Tile+at)
		case answer.By != nil:
			parts = append(parts, "by the user"+at)
		case at != "":
			parts = append(parts, at[1:])
		}
		lines = append(lines, "    answer: "+strings.Join(parts, " · "))
	}
	return lines
}
