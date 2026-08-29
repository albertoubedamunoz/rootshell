package update

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

var bin = []byte("fake binary contents")

func sum(b []byte) string {
	s := sha256.Sum256(b)
	return hex.EncodeToString(s[:])
}

// serve returns a release server; sums may override the SHA256SUMS text.
func serve(t *testing.T, version, sums string) *httptest.Server {
	t.Helper()
	name := Artifact("linux", "amd64")
	if sums == "" {
		sums = sum(bin) + "  *" + name + "\n"
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/LATEST", func(w http.ResponseWriter, r *http.Request) { fmt.Fprintln(w, version) })
	mux.HandleFunc("/"+version+"/SHA256SUMS", func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, sums) })
	mux.HandleFunc("/"+version+"/"+name, func(w http.ResponseWriter, r *http.Request) { w.Write(bin) })
	s := httptest.NewServer(mux)
	t.Cleanup(s.Close)
	return s
}

func TestLatest(t *testing.T) {
	s := serve(t, "0.2.3", "")
	v, err := Latest(context.Background(), s.URL)
	if err != nil || v != "0.2.3" {
		t.Fatal(v, err)
	}
}

func TestDownloadVerifies(t *testing.T) {
	s := serve(t, "0.2.3", "")
	data, err := Download(context.Background(), s.URL, "0.2.3", "linux", "amd64")
	if err != nil || !bytes.Equal(data, bin) {
		t.Fatal(err)
	}
}

func TestDownloadChecksumMismatch(t *testing.T) {
	s := serve(t, "0.2.3", sum([]byte("other"))+"  "+Artifact("linux", "amd64")+"\n")
	_, err := Download(context.Background(), s.URL, "0.2.3", "linux", "amd64")
	if err == nil || !strings.Contains(err.Error(), "checksum mismatch") {
		t.Fatal(err)
	}
}

func TestDownloadFallback(t *testing.T) {
	fb := serve(t, "0.2.3", "")
	old := GitHubBase
	GitHubBase = fb.URL + "/%s"
	t.Cleanup(func() { GitHubBase = old })
	primary := httptest.NewServer(http.NotFoundHandler())
	t.Cleanup(primary.Close)
	data, err := Download(context.Background(), primary.URL, "0.2.3", "linux", "amd64")
	if err != nil || !bytes.Equal(data, bin) {
		t.Fatal(err)
	}
}

func TestReplace(t *testing.T) {
	exe := filepath.Join(t.TempDir(), "rootshell-notify")
	if err := os.WriteFile(exe, []byte("old"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := Replace(exe, bin); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(exe)
	if err != nil || !bytes.Equal(got, bin) {
		t.Fatal(err)
	}
	st, _ := os.Stat(exe)
	if st.Mode().Perm() != 0o755 {
		t.Fatalf("mode %v", st.Mode())
	}
	if _, err := os.Stat(exe + ".new"); err == nil {
		t.Fatal(".new left behind")
	}
}
