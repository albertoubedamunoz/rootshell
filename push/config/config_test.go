package config

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/kitknox/rootshell/push/envelope"
)

func TestRoundTrip(t *testing.T) {
	dir := t.TempDir()
	t.Setenv(EnvPath, filepath.Join(dir, "sub", "config.json"))
	sk, _ := envelope.GeneratePrivateKey()
	p := &envelope.Pairing{Server: "https://push.example", DeviceLabel: "Phone", SenderCred: "rsc1.x", PublicKey: sk.PublicKey().Bytes()}

	c, err := Load()
	if err != nil || len(c.Devices) != 0 {
		t.Fatalf("empty load: %v %+v", err, c)
	}
	if c.Add(DeviceFromPairing(p)) {
		t.Fatal("first add reported replace")
	}
	if !c.Devices[0].HooksEnabled || len(c.HookDevices()) != 1 {
		t.Fatal("new pairing did not enable hooks")
	}
	if !c.Add(DeviceFromPairing(p)) || len(c.Devices) != 1 {
		t.Fatal("dedupe by sender cred failed")
	}
	if d, changed, err := c.SetHooksEnabled("Phone", false); err != nil || !changed || d.HooksEnabled || len(c.HookDevices()) != 0 {
		t.Fatalf("disable hooks: %+v %v %v", d, changed, err)
	}
	if _, changed, err := c.SetHooksEnabled("Phone", false); err != nil || changed {
		t.Fatalf("idempotent disable: %v %v", changed, err)
	}
	p2 := *p
	p2.SenderCred = "rsc1.y"
	if !c.Add(DeviceFromPairing(&p2)) || len(c.Devices) != 1 || c.Devices[0].SenderCred != "rsc1.y" || c.Devices[0].HooksEnabled {
		t.Fatal("re-pair by label did not replace")
	}
	if err := c.Save(); err != nil {
		t.Fatal(err)
	}
	st, _ := os.Stat(Path())
	if st.Mode().Perm() != 0o600 {
		t.Fatalf("perm %v", st.Mode())
	}
	if st, _ := os.Stat(filepath.Dir(Path())); st.Mode().Perm() != 0o700 {
		t.Fatalf("dir perm %v", st.Mode())
	}
	again, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	d, ok := again.Find("Phone")
	if !ok || d.SenderCred != "rsc1.y" || d.HooksEnabled {
		t.Fatalf("find: %+v", d)
	}
	if d, err := again.ToggleHooks("rsc1.y"); err != nil || !d.HooksEnabled || len(again.HookDevices()) != 1 {
		t.Fatalf("toggle hooks: %+v %v", d, err)
	}
	if _, _, err := again.SetHooksEnabled("missing", true); err != ErrNotFound {
		t.Fatalf("missing device: %v", err)
	}
	if _, err := d.Key(); err != nil {
		t.Fatal(err)
	}
	if _, err := again.Remove("Phone"); err != nil || len(again.Devices) != 0 {
		t.Fatal("remove")
	}
	if _, err := again.Remove("Phone"); err != ErrNotFound {
		t.Fatal(err)
	}
	if LogPath() != filepath.Join(dir, "sub", "hook.log") {
		t.Fatal(LogPath())
	}
}

func TestLoadSkipsLegacyEntries(t *testing.T) {
	t.Setenv(EnvPath, filepath.Join(t.TempDir(), "config.json"))
	sk, _ := envelope.GeneratePrivateKey()
	c := &Config{Devices: []Device{
		{Label: "Old", Server: "https://push.example", PublicKey: sk.PublicKey().Bytes()},
		{Label: "New", Server: "https://push.example", SenderCred: "rsc1.z", PublicKey: sk.PublicKey().Bytes()},
	}}
	if err := c.Save(); err != nil {
		t.Fatal(err)
	}
	got, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Devices) != 1 || got.Devices[0].Label != "New" || len(got.Skipped) != 1 || got.Skipped[0] != "Old" {
		t.Fatalf("%+v", got)
	}
}

func TestLogRotate(t *testing.T) {
	t.Setenv(EnvPath, filepath.Join(t.TempDir(), "config.json"))
	os.MkdirAll(Dir(), 0o700)
	os.WriteFile(LogPath(), make([]byte, logMaxBytes+1), 0o600)
	f, err := OpenLog()
	if err != nil {
		t.Fatal(err)
	}
	f.Close()
	if _, err := os.Stat(LogPath() + ".1"); err != nil {
		t.Fatal("not rotated")
	}
	if st, _ := os.Stat(LogPath()); st.Size() != 0 {
		t.Fatal("new log not empty")
	}
}
