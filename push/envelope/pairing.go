package envelope

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strings"
)

const (
	// PairingPrefix versions the bundle a device hands to a computer.
	PairingPrefix = "rspair1."
	// CredPrefix versions the opaque sender credential minted by the relay.
	CredPrefix = "rsc1."
)

var ErrPairing = errors.New("envelope: invalid pairing bundle")

// Pairing is everything a sender needs to push to one device. The relay never
// sees PublicKey; it travels device -> computer directly.
type Pairing struct {
	Server      string `json:"server"`
	DeviceLabel string `json:"label,omitempty"`
	SenderCred  string `json:"cred"`
	PublicKey   []byte `json:"pk"`
}

func (p *Pairing) Encode() (string, error) {
	if err := p.validate(); err != nil {
		return "", err
	}
	b, err := json.Marshal(p)
	if err != nil {
		return "", err
	}
	return PairingPrefix + b64.EncodeToString(b), nil
}

func DecodePairing(s string) (*Pairing, error) {
	s = strings.TrimSpace(s)
	if !strings.HasPrefix(s, PairingPrefix) {
		return nil, ErrPairing
	}
	raw, err := b64.DecodeString(strings.TrimPrefix(s, PairingPrefix))
	if err != nil {
		return nil, ErrPairing
	}
	var p Pairing
	if err := json.Unmarshal(raw, &p); err != nil {
		return nil, ErrPairing
	}
	if err := p.validate(); err != nil {
		return nil, err
	}
	return &p, nil
}

func (p *Pairing) validate() error {
	u, err := url.Parse(p.Server)
	if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return fmt.Errorf("%w: server url", ErrPairing)
	}
	if !strings.HasPrefix(p.SenderCred, CredPrefix) || len(p.SenderCred) == len(CredPrefix) {
		return fmt.Errorf("%w: sender credential", ErrPairing)
	}
	if _, err := ParsePublicKey(p.PublicKey); err != nil {
		return fmt.Errorf("%w: %v", ErrPairing, err)
	}
	return nil
}
