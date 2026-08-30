package main

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
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

func testDevice(t *testing.T, label, cred, server string, hooksEnabled bool) config.Device {
	t.Helper()
	sk, err := envelope.GeneratePrivateKey()
	if err != nil {
		t.Fatal(err)
	}
	return config.Device{
		Label:        label,
		Server:       server,
		SenderCred:   cred,
		PublicKey:    sk.PublicKey().Bytes(),
		HooksEnabled: hooksEnabled,
	}
}

func TestDevicesCommandsAndPicker(t *testing.T) {
	t.Setenv(config.EnvPath, filepath.Join(t.TempDir(), "config.json"))
	cfg := &config.Config{Devices: []config.Device{
		testDevice(t, "phone", "rsc1.phone", "https://push.example", true),
		testDevice(t, "tablet", "rsc1.tablet", "https://push.example", false),
	}}
	if err := cfg.Save(); err != nil {
		t.Fatal(err)
	}

	var out, errb bytes.Buffer
	if code := run([]string{"devices"}, strings.NewReader(""), &out, &errb); code != exitOK {
		t.Fatal(code, errb.String())
	}
	if got := out.String(); !strings.Contains(got, "[1] on") || !strings.Contains(got, "phone") || !strings.Contains(got, "[2] off") || !strings.Contains(got, "tablet") {
		t.Fatal(got)
	}

	out.Reset()
	if code := run([]string{"devices", "off", "phone"}, strings.NewReader(""), &out, &errb); code != exitOK || !strings.Contains(out.String(), "phone: agent hooks off") {
		t.Fatalf("off: %d %q %q", code, out.String(), errb.String())
	}
	out.Reset()
	if code := run([]string{"devices", "off", "phone"}, strings.NewReader(""), &out, &errb); code != exitOK || !strings.Contains(out.String(), "already off") {
		t.Fatalf("idempotent off: %d %q %q", code, out.String(), errb.String())
	}
	out.Reset()
	if code := run([]string{"devices", "toggle", "tablet"}, strings.NewReader(""), &out, &errb); code != exitOK || !strings.Contains(out.String(), "tablet: agent hooks on") {
		t.Fatalf("toggle: %d %q %q", code, out.String(), errb.String())
	}

	out.Reset()
	errb.Reset()
	if code := cmdDevices(nil, strings.NewReader("nope\n3\n1\n2\n\n"), &out, &errb, true); code != exitOK {
		t.Fatalf("picker: %d %q", code, errb.String())
	}
	if strings.Count(errb.String(), "Enter a number from 1 to 2") != 2 || !strings.Contains(out.String(), "phone: agent hooks on") || !strings.Contains(out.String(), "tablet: agent hooks off") {
		t.Fatalf("picker output: %q %q", out.String(), errb.String())
	}
	cfg, err := config.Load()
	if err != nil || !cfg.Devices[0].HooksEnabled || cfg.Devices[1].HooksEnabled {
		t.Fatalf("picker state: %v %+v", err, cfg)
	}
	out.Reset()
	errb.Reset()
	if code := run([]string{"devices", "on", "tablet"}, strings.NewReader(""), &out, &errb); code != exitOK || !strings.Contains(out.String(), "tablet: agent hooks on") {
		t.Fatalf("on: %d %q %q", code, out.String(), errb.String())
	}
	out.Reset()
	if code := cmdDevices(nil, strings.NewReader(""), &out, &errb, true); code != exitOK {
		t.Fatalf("picker EOF: %d %q", code, errb.String())
	}

	for _, args := range [][]string{{"devices", "bad", "phone"}, {"devices", "on"}, {"devices", "on", "missing"}} {
		out.Reset()
		errb.Reset()
		code := run(args, strings.NewReader(""), &out, &errb)
		if code == exitOK {
			t.Fatalf("accepted %v: %q", args, out.String())
		}
	}
}

func TestHookDeviceSelectionDoesNotLimitManualDelivery(t *testing.T) {
	t.Setenv(config.EnvPath, filepath.Join(t.TempDir(), "config.json"))
	var mu sync.Mutex
	var credentials []string
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/push" {
			http.NotFound(w, r)
			return
		}
		mu.Lock()
		credentials = append(credentials, r.Header.Get("Authorization"))
		mu.Unlock()
		w.WriteHeader(http.StatusAccepted)
	}))
	defer srv.Close()
	old := newClient
	newClient = func() *client.Client {
		c := client.New("test")
		c.HTTP = srv.Client()
		return c
	}
	t.Cleanup(func() { newClient = old })

	cfg := &config.Config{Devices: []config.Device{
		testDevice(t, "phone", "rsc1.phone", srv.URL, true),
		testDevice(t, "tablet", "rsc1.tablet", srv.URL, false),
	}}
	if err := cfg.Save(); err != nil {
		t.Fatal(err)
	}
	reset := func() {
		mu.Lock()
		credentials = nil
		mu.Unlock()
	}
	gotCredentials := func() []string {
		mu.Lock()
		defer mu.Unlock()
		return append([]string(nil), credentials...)
	}
	runOK := func(args []string, input string) {
		t.Helper()
		var out, errb bytes.Buffer
		if code := run(args, strings.NewReader(input), &out, &errb); code != exitOK {
			t.Fatalf("%v: exit %d: %s %s", args, code, out.String(), errb.String())
		}
	}

	payload := `{"session_id":"sess-9","cwd":"/srv/app","turn_id":"turn-42","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"Done."}`
	runOK([]string{"hook", "--agent", "codex"}, payload)
	if got := gotCredentials(); len(got) != 1 || got[0] != "Bearer rsc1.phone" {
		t.Fatalf("hook recipients: %v", got)
	}

	reset()
	runOK([]string{"test", "tablet"}, "")
	if got := gotCredentials(); len(got) != 1 || got[0] != "Bearer rsc1.tablet" {
		t.Fatalf("explicit test recipients: %v", got)
	}

	reset()
	runOK([]string{"send", "--title", "Manual"}, "")
	if got := gotCredentials(); len(got) != 2 {
		t.Fatalf("broadcast recipients: %v", got)
	}

	reset()
	runOK([]string{"send", "--title", "Manual", "--device", "tablet"}, "")
	if got := gotCredentials(); len(got) != 1 || got[0] != "Bearer rsc1.tablet" {
		t.Fatalf("explicit send recipients: %v", got)
	}

	cfg.Devices[0].HooksEnabled = false
	if err := cfg.Save(); err != nil {
		t.Fatal(err)
	}
	reset()
	runOK([]string{"hook", "--agent", "codex"}, "not even parsed")
	if got := gotCredentials(); len(got) != 0 {
		t.Fatalf("all-disabled hook recipients: %v", got)
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
	if err != nil || len(cfg.Devices) != 1 || !cfg.Devices[0].HooksEnabled {
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
