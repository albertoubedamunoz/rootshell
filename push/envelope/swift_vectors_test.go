package envelope

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// Envelopes sealed by the Swift implementation (PUSH_WRITE_SWIFT_VECTORS=1
// swift test) against the key in vectors.json.
func TestSwiftVectors(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("testdata", "swift-vectors.json"))
	if err != nil {
		t.Skip("no swift vectors")
	}
	var sv struct {
		Cases []struct {
			Name     string   `json:"name"`
			EID      string   `json:"eid"`
			Envelope Envelope `json:"envelope"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(raw, &sv); err != nil {
		t.Fatal(err)
	}
	gv, _ := os.ReadFile(filepath.Join("testdata", "vectors.json"))
	var v vectors
	json.Unmarshal(gv, &v)
	seed, _ := base64.StdEncoding.DecodeString(v.Seed)
	sk, _ := NewPrivateKey(seed)
	want := map[string]*Header{}
	for _, c := range v.Cases {
		want[c.Name] = c.Header
	}
	for _, c := range sv.Cases {
		h, err := Open(sk, &c.Envelope)
		if err != nil {
			t.Fatalf("%s: %v", c.Name, err)
		}
		got, _ := json.Marshal(h)
		exp, _ := json.Marshal(want[c.Name])
		if !bytes.Equal(got, exp) {
			t.Fatalf("%s: %s != %s", c.Name, got, exp)
		}
	}
}
