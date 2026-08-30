// Package config stores paired devices in ~/.config/rootshell-push/config.json.
package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/kitknox/rootshell/push/envelope"
)

const (
	Version = 1
	EnvPath = "ROOTSHELL_PUSH_CONFIG"

	logMaxBytes = 1 << 20
)

var ErrNotFound = errors.New("config: device not found")

type Device struct {
	Label      string    `json:"label"`
	Server     string    `json:"server"`
	SenderCred string    `json:"sender_cred"`
	PublicKey  []byte    `json:"public_key"` // base64 std via encoding/json
	AddedAt    time.Time `json:"added_at"`
}

// Key parses the device's X-Wing public key.
func (d *Device) Key() (*envelope.PublicKey, error) {
	return envelope.ParsePublicKey(d.PublicKey)
}

func DeviceFromPairing(p *envelope.Pairing) Device {
	label := p.DeviceLabel
	if label == "" {
		label = "device"
	}
	return Device{Label: label, Server: p.Server, SenderCred: p.SenderCred, PublicKey: p.PublicKey, AddedAt: time.Now().UTC().Truncate(time.Second)}
}

type Config struct {
	Version int      `json:"version"`
	Devices []Device `json:"devices"`
	// Skipped lists labels of pre-stateless entries (no sender_cred) dropped by Load.
	Skipped []string `json:"-"`
}

// Dir returns the config directory, honoring $ROOTSHELL_PUSH_CONFIG.
func Dir() string {
	if p := os.Getenv(EnvPath); p != "" {
		return filepath.Dir(p)
	}
	base := os.Getenv("XDG_CONFIG_HOME")
	if base == "" {
		home, _ := os.UserHomeDir()
		base = filepath.Join(home, ".config")
	}
	return filepath.Join(base, "rootshell-push")
}

func Path() string {
	if p := os.Getenv(EnvPath); p != "" {
		return p
	}
	return filepath.Join(Dir(), "config.json")
}

func LogPath() string { return filepath.Join(Dir(), "hook.log") }

// Load returns an empty config when the file does not exist.
func Load() (*Config, error) {
	raw, err := os.ReadFile(Path())
	if errors.Is(err, os.ErrNotExist) {
		return &Config{Version: Version}, nil
	}
	if err != nil {
		return nil, err
	}
	var c Config
	if err := json.Unmarshal(raw, &c); err != nil {
		return nil, fmt.Errorf("config: parse %s: %w", Path(), err)
	}
	if c.Version == 0 {
		c.Version = Version
	}
	if c.Version > Version {
		return nil, fmt.Errorf("config: version %d newer than supported %d", c.Version, Version)
	}
	kept := c.Devices[:0]
	for _, d := range c.Devices {
		if d.SenderCred == "" {
			c.Skipped = append(c.Skipped, d.Label)
			continue
		}
		if _, err := d.Key(); err != nil {
			return nil, fmt.Errorf("config: device %q: %w", d.Label, err)
		}
		kept = append(kept, d)
	}
	c.Devices = kept
	return &c, nil
}

// Save writes atomically with 0600 (dir 0700).
func (c *Config) Save() error {
	c.Version = Version
	if c.Devices == nil {
		c.Devices = []Device{}
	}
	b, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	return WriteFileAtomic(Path(), append(b, '\n'), 0o600)
}

// WriteFileAtomic writes via a temp file in the same directory and renames.
func WriteFileAtomic(path string, data []byte, perm os.FileMode) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, "."+filepath.Base(path)+".*")
	if err != nil {
		return err
	}
	name := tmp.Name()
	cleanup := func() { tmp.Close(); os.Remove(name) }
	if err := tmp.Chmod(perm); err != nil {
		cleanup()
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		cleanup()
		return err
	}
	if err := tmp.Sync(); err != nil {
		cleanup()
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(name)
		return err
	}
	if err := os.Rename(name, path); err != nil {
		os.Remove(name)
		return err
	}
	return nil
}

// Add inserts or replaces an entry with the same sender_cred or label
// (re-pairing after the device re-registered). Returns true if replaced.
func (c *Config) Add(d Device) bool {
	for i := range c.Devices {
		if c.Devices[i].SenderCred == d.SenderCred || c.Devices[i].Label == d.Label {
			c.Devices[i] = d
			return true
		}
	}
	c.Devices = append(c.Devices, d)
	return false
}

// Find matches a label (or the exact sender credential).
func (c *Config) Find(label string) (*Device, bool) {
	for i := range c.Devices {
		if c.Devices[i].Label == label || c.Devices[i].SenderCred == label {
			return &c.Devices[i], true
		}
	}
	return nil, false
}

func (c *Config) Remove(label string) (Device, error) {
	d, ok := c.Find(label)
	if !ok {
		return Device{}, ErrNotFound
	}
	removed := *d
	out := c.Devices[:0]
	for _, x := range c.Devices {
		if x.SenderCred != removed.SenderCred {
			out = append(out, x)
		}
	}
	c.Devices = out
	return removed, nil
}

func (c *Config) List() []Device { return c.Devices }

// OpenLog opens hook.log for append, rotating to hook.log.1 past 1 MiB.
func OpenLog() (*os.File, error) {
	path := LogPath()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, err
	}
	if st, err := os.Stat(path); err == nil && st.Size() > logMaxBytes {
		os.Rename(path, path+".1")
	}
	return os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
}
