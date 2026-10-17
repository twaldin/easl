package measure

import (
	"strings"

	"golang.org/x/sys/unix"
)

func openNoFollow(path string) (int, error) {
	path = StandardPath(path)
	if !strings.HasPrefix(path, "/") || path == "/" {
		return -1, unix.ELOOP
	}
	parts := strings.Split(path[1:], "/")
	const directory = unix.O_PATH | unix.O_DIRECTORY | unix.O_NOFOLLOW | unix.O_CLOEXEC
	dir, err := unix.Open("/", directory, 0)
	if err != nil {
		return -1, err
	}
	for _, component := range parts[:len(parts)-1] {
		if component == "" || component == "." || component == ".." {
			unix.Close(dir)
			return -1, unix.ELOOP
		}
		next, err := unix.Openat(dir, component, directory, 0)
		unix.Close(dir)
		if err != nil {
			return -1, err
		}
		dir = next
	}
	last := parts[len(parts)-1]
	if last == "" || last == "." || last == ".." {
		unix.Close(dir)
		return -1, unix.ELOOP
	}
	fd, err := unix.Openat(dir, last, unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
	unix.Close(dir)
	return fd, err
}
