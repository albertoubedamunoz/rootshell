// Package update fetches, verifies and installs rootshell-notify releases.
package update

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

// DefaultBase is the primary release server.
const DefaultBase = "https://push.rootshell.com/releases"

// GitHubBase is the fallback; %s is the version. A var so tests can redirect it.
var GitHubBase = "https://github.com/kitknox/rootshell/releases/download/push%%2Fv%s"

const (
	maxBinary = 64 << 20
	maxText   = 64 << 10
)

// Artifact returns the release file name for a platform.
func Artifact(goos, goarch string) string {
	return "rootshell-notify_" + goos + "_" + goarch
}

// Latest returns the newest released version from <base>/LATEST.
func Latest(ctx context.Context, base string) (string, error) {
	b, err := fetch(ctx, strings.TrimRight(base, "/")+"/LATEST", maxText)
	if err != nil {
		return "", err
	}
	v := strings.TrimSpace(string(b))
	if v == "" || strings.ContainsAny(v, " \t\n/") {
		return "", fmt.Errorf("bad LATEST %q", v)
	}
	return v, nil
}

// Download fetches and verifies the artifact for version, trying base and
// then GitHub for each file.
func Download(ctx context.Context, base, version, goos, goarch string) ([]byte, error) {
	name := Artifact(goos, goarch)
	bases := []string{
		strings.TrimRight(base, "/") + "/" + version,
		fmt.Sprintf(GitHubBase, version),
	}
	sums, err := fetchAny(ctx, bases, "SHA256SUMS", maxText)
	if err != nil {
		return nil, err
	}
	want, err := lookup(sums, name)
	if err != nil {
		return nil, err
	}
	data, err := fetchAny(ctx, bases, name, maxBinary)
	if err != nil {
		return nil, err
	}
	sum := sha256.Sum256(data)
	if got := hex.EncodeToString(sum[:]); got != want {
		return nil, fmt.Errorf("checksum mismatch for %s: expected %s, got %s", name, want, got)
	}
	return data, nil
}

// Replace atomically swaps the binary at exePath with data.
func Replace(exePath string, data []byte) error {
	st, err := os.Stat(exePath)
	if err != nil {
		return err
	}
	tmp := exePath + ".new"
	err = os.WriteFile(tmp, data, st.Mode().Perm())
	if err == nil {
		err = os.Chmod(tmp, st.Mode().Perm())
	}
	if err == nil {
		err = os.Rename(tmp, exePath)
	}
	if err != nil {
		os.Remove(tmp)
		if errors.Is(err, fs.ErrPermission) || errors.Is(err, syscall.EACCES) || errors.Is(err, syscall.EPERM) {
			return fmt.Errorf("cannot write %s: permission denied; for a system install run `sudo rootshell-notify upgrade`", filepath.Dir(exePath))
		}
		return err
	}
	return nil
}

// lookup finds name in shasum-format text; a leading * on the name is allowed.
func lookup(sums []byte, name string) (string, error) {
	sc := bufio.NewScanner(strings.NewReader(string(sums)))
	for sc.Scan() {
		f := strings.Fields(sc.Text())
		if len(f) == 2 && strings.TrimPrefix(f[1], "*") == name && len(f[0]) == 64 {
			return strings.ToLower(f[0]), nil
		}
	}
	return "", fmt.Errorf("no checksum for %s in SHA256SUMS", name)
}

func fetchAny(ctx context.Context, bases []string, name string, limit int64) ([]byte, error) {
	var first error
	for _, b := range bases {
		data, err := fetch(ctx, b+"/"+name, limit)
		if err == nil {
			return data, nil
		}
		if first == nil {
			first = err
		}
		if ctx.Err() != nil {
			break
		}
	}
	return nil, first
}

func fetch(ctx context.Context, url string, limit int64) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("GET %s: %s", url, resp.Status)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, limit+1))
	if err != nil {
		return nil, fmt.Errorf("GET %s: %w", url, err)
	}
	if int64(len(data)) > limit {
		return nil, fmt.Errorf("GET %s: response too large", url)
	}
	return data, nil
}
