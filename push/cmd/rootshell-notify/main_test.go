package main

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/kitknox/rootshell/push/client"
	"github.com/kitknox/rootshell/push/config"
	"github.com/kitknox/rootshell/push/envelope"
	"github.com/kitknox/rootshell/push/installer"
)

func TestHookIsSilentWithoutDevices(t *testing.T) {
	t.Setenv(config.EnvPath, filepath.Join(t.TempDir(), "config.json"))
	var out, errb bytes.Buffer
	for _, in := range []string{"", "garbage", `{"transcript_path":"x","hook_event_name":"Stop"}`} {
		if code := run([]string{"hook", "--agent", "claude-code"}, strings.NewReader(in), &out, &errb); code != 0 {
			t.Fatalf("hook exit %d", code)
		}
	}
	if out.Len() != 0 || errb.Len() != 0 {
		t.Fatalf("hook wrote output: %q %q", out.String(), errb.String())
	}
}

func TestUsageExitCodes(t *testing.T) {
	var out, errb bytes.Buffer
	if code := run(nil, strings.NewReader(""), &out, &errb); code != exitUsage {
		t.Fatal(code)
	}
	if code := run([]string{"bogus"}, strings.NewReader(""), &out, &errb); code != exitUsage {
		t.Fatal(code)
	}
	if code := run([]string{"send"}, strings.NewReader(""), &out, &errb); code != exitUsage {
		t.Fatal(code)
	}
	if code := run([]string{"install", "vim"}, strings.NewReader(""), &out, &errb); code != exitUsage {
		t.Fatal(code)
	}
	out.Reset()
	if code := run([]string{"help"}, strings.NewReader(""), &out, &errb); code != 0 || !strings.Contains(out.String(), "Usage:") {
		t.Fatal(code)
	}
}

func TestParseFlags(t *testing.T) {
	f, err := parseFlags([]string{"claude-code", "--project", "--title=Hi there", "--body", "b", "--yes"}, "project", "yes")
	if err != nil {
		t.Fatal(err)
	}
	if len(f.args) != 1 || f.args[0] != "claude-code" || !f.has("project") || f.vals["title"] != "Hi there" || f.vals["body"] != "b" || !f.has("yes") {
		t.Fatalf("%+v", f)
	}
	if _, err := parseFlags([]string{"--title"}); err == nil {
		t.Fatal("missing value accepted")
	}
}

// setupEnv points HOME and the config at temp dirs and stands up a TLS relay.
func setupEnv(t *testing.T) (home, bundle string) {
	t.Helper()
	home = t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv(config.EnvPath, filepath.Join(home, "config.json"))
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v1/push" {
			w.WriteHeader(http.StatusAccepted)
		}
	}))
	t.Cleanup(srv.Close)
	old := newClient
	newClient = func() *client.Client {
		c := client.New("test")
		c.HTTP = srv.Client()
		return c
	}
	t.Cleanup(func() { newClient = old })
	sk, _ := envelope.GeneratePrivateKey()
	p := &envelope.Pairing{Server: srv.URL, DeviceLabel: "phone", SenderCred: "rsc1.tok", PublicKey: sk.PublicKey().Bytes()}
	bundle, err := p.Encode()
	if err != nil {
		t.Fatal(err)
	}
	return home, bundle
}

func TestSetupNoHooks(t *testing.T) {
	home, bundle := setupEnv(t)
	var out, errb bytes.Buffer
	if code := run([]string{"setup", "--pair", bundle, "--hooks", "none"}, strings.NewReader(""), &out, &errb); code != 0 {
		t.Fatalf("exit %d: %s %s", code, out.String(), errb.String())
	}
	if !strings.Contains(out.String(), "Paired with phone") || !strings.Contains(out.String(), "Sent to phone") {
		t.Fatal(out.String())
	}
	cfg, err := config.Load()
	if err != nil || len(cfg.Devices) != 1 {
		t.Fatalf("%v %+v", err, cfg)
	}
	if _, err := os.Stat(filepath.Join(home, ".claude", "settings.json")); err == nil {
		t.Fatal("hook installed with --hooks none")
	}
	if strings.Contains(out.String(), "No Claude Code or Codex config found") {
		t.Fatal("hint printed for --hooks none")
	}
}

func TestSetupClaudeCode(t *testing.T) {
	home, bundle := setupEnv(t)
	var out, errb bytes.Buffer
	// Bundle from stdin.
	if code := run([]string{"setup", "--hooks", "claude-code"}, strings.NewReader(bundle+"\n"), &out, &errb); code != 0 {
		t.Fatalf("exit %d: %s %s", code, out.String(), errb.String())
	}
	if !strings.Contains(out.String(), "Installed Claude Code hook") {
		t.Fatal(out.String())
	}
	st, err := installer.GetStatus(installer.ClaudeCode, false)
	if err != nil || !st.Installed || st.Path != filepath.Join(home, ".claude", "settings.json") {
		t.Fatalf("%v %+v", err, st)
	}
	out.Reset()
	if code := run([]string{"setup", "--pair", bundle, "--hooks", "claude-code"}, strings.NewReader(""), &out, &errb); code != 0 {
		t.Fatalf("exit %d: %s", code, errb.String())
	}
	if !strings.Contains(out.String(), "Claude Code hook already installed") {
		t.Fatal(out.String())
	}
}

func TestSetupAuto(t *testing.T) {
	home, bundle := setupEnv(t)
	var out, errb bytes.Buffer
	if code := run([]string{"setup", "--pair", bundle}, strings.NewReader(""), &out, &errb); code != 0 {
		t.Fatalf("exit %d: %s", code, errb.String())
	}
	if !strings.Contains(out.String(), "No Claude Code or Codex config found") {
		t.Fatal(out.String())
	}
	os.MkdirAll(filepath.Join(home, ".codex"), 0o700)
	out.Reset()
	if code := run([]string{"setup", "--pair", bundle}, strings.NewReader(""), &out, &errb); code != 0 {
		t.Fatalf("exit %d: %s", code, errb.String())
	}
	if !strings.Contains(out.String(), "Installed Codex hook") || !strings.Contains(out.String(), installer.CodexTrustNote) {
		t.Fatal(out.String())
	}
	if st, _ := installer.GetStatus(installer.ClaudeCode, false); st.Exists {
		t.Fatal("claude hook installed without ~/.claude")
	}
	if code := run([]string{"setup", "--pair", bundle, "--hooks", "vim"}, strings.NewReader(""), &out, &errb); code != exitUsage {
		t.Fatal(code)
	}
	if code := run([]string{"setup", "--pair", "junk"}, strings.NewReader(""), &out, &errb); code != exitError {
		t.Fatal(code)
	}
}

func TestUpgradeCheck(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/LATEST" {
			http.NotFound(w, r)
			return
		}
		w.Write([]byte("9.9.9\n"))
	}))
	defer srv.Close()
	var out, errb bytes.Buffer
	if code := run([]string{"upgrade", "--check", "--server", srv.URL}, strings.NewReader(""), &out, &errb); code != exitOutdated {
		t.Fatal(code, errb.String())
	}
	if !strings.Contains(out.String(), "9.9.9 available") {
		t.Fatal(out.String())
	}
	out.Reset()
	if code := run([]string{"upgrade", "--check", "--server", srv.URL, "--version", version}, strings.NewReader(""), &out, &errb); code != exitOK {
		t.Fatal(code, errb.String())
	}
	if !strings.Contains(out.String(), "is current") {
		t.Fatal(out.String())
	}
	if code := run([]string{"upgrade", "extra"}, strings.NewReader(""), &out, &errb); code != exitUsage {
		t.Fatal(code)
	}
	if s := updateStatus(srv.URL); !strings.Contains(s, "9.9.9 available") {
		t.Fatal(s)
	}
	if s := updateStatus("http://127.0.0.1:1"); s != "unknown" {
		t.Fatal(s)
	}
}
