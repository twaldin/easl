package store

import (
	"encoding/json"
	"errors"
	"io/fs"
	"os"
)

// ReadRoots is a list of board roots in a file (easld's `<home>/open-boards.json`, the boards it
// reopens at start; the app's AppPaths.openBoards is one too): none when there is no file.
func ReadRoots(path string) ([]string, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var roots []string
	if err := json.Unmarshal(data, &roots); err != nil {
		return nil, err
	}
	return roots, nil
}

// WriteRoots replaces the list of board roots at path.
func WriteRoots(path string, roots []string) error {
	if roots == nil {
		roots = []string{}
	}
	data, err := json.Marshal(roots)
	if err != nil {
		return err
	}
	return writeAtomic(path, data)
}
