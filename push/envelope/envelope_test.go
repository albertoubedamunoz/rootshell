package envelope

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

var update = flag.Bool("update", false, "regenerate testdata/vectors.json")

func testHeader() *Header {
	return &Header{
		Kind: "agent", Agent: "claude-code", Status: "done",
		Title: "Claude Code · rootshell", Body: "Finished the refactor and ran the tests.",
		Thread: "sess-1",
		Route:  &Route{Pane: "6F9619FF-8B86-D011-B42D-00C04FC964FF", TmuxPane: "%3", TmuxSession: "main", Host: "kit@dev", Cwd: "/home/kit/rootshell"},
	}
}

func TestSealOpenRoundTrip(t *testing.T) {
	sk, err := GeneratePrivateKey()
	if err != nil {
		t.Fatal(err)
	}
	env, err := Seal(sk.PublicKey(), "evt-1", testHeader())
	if err != nil {
		t.Fatal(err)
	}
	if err := env.Validate(); err != nil {
		t.Fatal(err)
	}
	h, err := Open(sk, env)
	if err != nil {
		t.Fatal(err)
	}
	if h.Title != "Claude Code · rootshell" || h.Route.TmuxPane != "%3" || h.V != Version {
		t.Fatalf("unexpected header %+v", h)
	}
	if b, _ := json.Marshal(env); len(b) > 4096-300 {
		t.Fatalf("envelope too large for APNs: %d", len(b))
	}
}

func TestOpenRejectsTampering(t *testing.T) {
	sk, _ := GeneratePrivateKey()
	other, _ := GeneratePrivateKey()
	env, _ := Seal(sk.PublicKey(), "evt-1", testHeader())

	if _, err := Open(other, env); err == nil {
		t.Fatal("wrong key accepted")
	}
	swapped := *env
	swapped.EID = "evt-2"
	if _, err := Open(sk, &swapped); err == nil {
		t.Fatal("event id swap accepted")
	}
	ct, _ := b64.DecodeString(env.CT)
	ct[0] ^= 1
	flipped := *env
	flipped.CT = b64.EncodeToString(ct)
	if _, err := Open(sk, &flipped); err == nil {
		t.Fatal("bit flip accepted")
	}
	short := *env
	short.Enc = short.Enc[:100]
	if err := short.Validate(); !errors.Is(err, ErrBadEnvelope) {
		t.Fatalf("short enc: %v", err)
	}
	for _, bad := range []string{"", "a b", strings.Repeat("x", 65), "é"} {
		if err := ValidateEventID(bad); err == nil {
			t.Fatalf("event id %q accepted", bad)
		}
	}
}

func TestSealRejectsOversizedHeader(t *testing.T) {
	sk, _ := GeneratePrivateKey()
	h := testHeader()
	h.Body = strings.Repeat("x", MaxHeaderBytes)
	if _, err := Seal(sk.PublicKey(), "evt", h); !errors.Is(err, ErrHeaderTooLarge) {
		t.Fatalf("got %v", err)
	}
}

func TestKeySerialization(t *testing.T) {
	sk, _ := GeneratePrivateKey()
	seed, _ := sk.Bytes()
	if len(seed) != SeedSize {
		t.Fatal(len(seed))
	}
	again, err := NewPrivateKey(seed)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(again.PublicKey().Bytes(), sk.PublicKey().Bytes()) {
		t.Fatal("seed did not round trip")
	}
	if _, err := ParsePublicKey(make([]byte, 10)); !errors.Is(err, ErrKeySize) {
		t.Fatal(err)
	}
}

func TestPairingRoundTrip(t *testing.T) {
	sk, _ := GeneratePrivateKey()
	p := &Pairing{Server: "https://push.rootshell.com", DeviceLabel: "Kit's Mac", SenderCred: "rsc1.tok", PublicKey: sk.PublicKey().Bytes()}
	s, err := p.Encode()
	if err != nil {
		t.Fatal(err)
	}
	got, err := DecodePairing("  " + s + "\n")
	if err != nil {
		t.Fatal(err)
	}
	if got.SenderCred != "rsc1.tok" || !bytes.Equal(got.PublicKey, p.PublicKey) {
		t.Fatal("mismatch")
	}
	for _, bad := range []Pairing{
		{Server: "http://push.rootshell.com", SenderCred: "rsc1.b", PublicKey: p.PublicKey},
		{Server: "https://u:p@push.rootshell.com", SenderCred: "rsc1.b", PublicKey: p.PublicKey},
		{Server: "https://push.rootshell.com", SenderCred: "", PublicKey: p.PublicKey},
		{Server: "https://push.rootshell.com", SenderCred: "rsc1.", PublicKey: p.PublicKey},
		{Server: "https://push.rootshell.com", SenderCred: "rss_b", PublicKey: p.PublicKey},
		{Server: "https://push.rootshell.com", SenderCred: "rsc1.b", PublicKey: p.PublicKey[:10]},
	} {
		if _, err := bad.Encode(); err == nil {
			t.Fatalf("accepted %+v", bad)
		}
	}
	if _, err := DecodePairing("nope"); err == nil {
		t.Fatal("prefix not enforced")
	}
}

// Vectors are consumed by the Swift implementation in Packages/RootshellPushKit.
type vectors struct {
	Seed      string       `json:"seed"`
	PublicKey string       `json:"public_key"`
	Info      string       `json:"info"`
	Cases     []vectorCase `json:"cases"`
	Pairing   string       `json:"pairing"`
}

type vectorCase struct {
	Name     string   `json:"name"`
	EID      string   `json:"eid"`
	Header   *Header  `json:"header"`
	Envelope Envelope `json:"envelope"`
}

func TestVectors(t *testing.T) {
	path := filepath.Join("testdata", "vectors.json")
	std := base64.StdEncoding
	if *update {
		seed := make([]byte, SeedSize)
		for i := range seed {
			seed[i] = byte(i)
		}
		sk, _ := NewPrivateKey(seed)
		var v vectors
		v.Seed = std.EncodeToString(seed)
		v.PublicKey = std.EncodeToString(sk.PublicKey().Bytes())
		v.Info = Info
		for _, c := range []struct {
			name, eid string
			h         *Header
		}{
			{"agent-done", "evt-1", testHeader()},
			{"minimal", "evt-2", &Header{Kind: "generic", Title: "Hi"}},
			{"unicode", "evt-3", &Header{Kind: "generic", Title: "日本語 🚀", Body: "élan"}},
		} {
			env, err := Seal(sk.PublicKey(), c.eid, c.h)
			if err != nil {
				t.Fatal(err)
			}
			v.Cases = append(v.Cases, vectorCase{c.name, c.eid, c.h, *env})
		}
		p := &Pairing{Server: "https://push.rootshell.com", DeviceLabel: "Test", SenderCred: "rsc1.test", PublicKey: sk.PublicKey().Bytes()}
		v.Pairing, _ = p.Encode()
		b, _ := json.MarshalIndent(v, "", "  ")
		os.MkdirAll("testdata", 0o755)
		if err := os.WriteFile(path, b, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Skip("no vectors; run with -update")
	}
	var v vectors
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	seed, _ := std.DecodeString(v.Seed)
	sk, err := NewPrivateKey(seed)
	if err != nil {
		t.Fatal(err)
	}
	if std.EncodeToString(sk.PublicKey().Bytes()) != v.PublicKey {
		t.Fatal("public key drifted")
	}
	for _, c := range v.Cases {
		h, err := Open(sk, &c.Envelope)
		if err != nil {
			t.Fatalf("%s: %v", c.Name, err)
		}
		want, _ := json.Marshal(c.Header)
		got, _ := json.Marshal(h)
		if !bytes.Equal(want, got) {
			t.Fatalf("%s: %s != %s", c.Name, got, want)
		}
	}
	p, err := DecodePairing(v.Pairing)
	if err != nil || p.SenderCred != "rsc1.test" {
		t.Fatalf("pairing vector: %v %+v", err, p)
	}
}
