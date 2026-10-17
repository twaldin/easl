package measure

import (
	"path/filepath"

	"golang.org/x/sys/unix"
)

func openNoFollow(path string) (int, error) {
	path = StandardPath(path)
	if !filepath.IsAbs(path) || path == "/" {
		return -1, unix.ELOOP
	}
	return unix.Open(path, unix.O_RDONLY|unix.O_NOFOLLOW_ANY|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
}
