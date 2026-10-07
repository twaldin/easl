package store

import (
	"encoding/json"
	"errors"
	"io/fs"
	"os"
)

// Reopened is a board easld reopens at start (`<home>/open-boards.json`): Board, its id, is the
// board; Root is a directory it was opened from, tried first. A repository board's own root may
// not open it (a bare repository's is its common directory's parent, which no worktree
// contains), and the worktree it was opened from may be gone by then.
type Reopened struct {
	Root  string `json:"root"`
	Board string `json:"board"`
}

// ReadReopened is the list of boards to reopen at path: none when there is no file.
func ReadReopened(path string) ([]Reopened, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var boards []Reopened
	if err := json.Unmarshal(data, &boards); err != nil {
		return nil, err
	}
	return boards, nil
}

// WriteReopened replaces the list of boards to reopen at path.
func WriteReopened(path string, boards []Reopened) error {
	if boards == nil {
		boards = []Reopened{}
	}
	data, err := json.Marshal(boards)
	if err != nil {
		return err
	}
	return writeAtomic(path, data)
}
