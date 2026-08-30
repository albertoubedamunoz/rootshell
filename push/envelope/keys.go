// Package envelope implements the rootshell push wire format: HPKE (RFC 9180)
// base mode with the X-Wing hybrid KEM (ML-KEM-768 + X25519), HKDF-SHA256 and
// AES-256-GCM. The relay only ever sees the output of Seal.
package envelope

import (
	"crypto/hpke"
	"errors"
	"fmt"
)

const (
	// KEMID is the HPKE registry id of X-Wing (draft-ietf-hpke-pq).
	KEMID = 0x647a

	SeedSize      = 32
	PublicKeySize = 1216
	EncSize       = 1120
)

var (
	ErrKeySize = errors.New("envelope: bad key size")
)

func kem() hpke.KEM   { return hpke.MLKEM768X25519() }
func kdf() hpke.KDF   { return hpke.HKDFSHA256() }
func aead() hpke.AEAD { return hpke.AES256GCM() }

// PublicKey is an X-Wing encapsulation key.
type PublicKey struct{ k hpke.PublicKey }

// PrivateKey is an X-Wing decapsulation key, serialized as its 32-byte seed.
type PrivateKey struct{ k hpke.PrivateKey }

func ParsePublicKey(b []byte) (*PublicKey, error) {
	if len(b) != PublicKeySize {
		return nil, fmt.Errorf("%w: public key %d bytes", ErrKeySize, len(b))
	}
	k, err := kem().NewPublicKey(b)
	if err != nil {
		return nil, err
	}
	return &PublicKey{k}, nil
}

func (p *PublicKey) Bytes() []byte { return p.k.Bytes() }

func GeneratePrivateKey() (*PrivateKey, error) {
	k, err := kem().GenerateKey()
	if err != nil {
		return nil, err
	}
	return &PrivateKey{k}, nil
}

func NewPrivateKey(seed []byte) (*PrivateKey, error) {
	if len(seed) != SeedSize {
		return nil, fmt.Errorf("%w: seed %d bytes", ErrKeySize, len(seed))
	}
	k, err := kem().NewPrivateKey(seed)
	if err != nil {
		return nil, err
	}
	return &PrivateKey{k}, nil
}

func (p *PrivateKey) Bytes() ([]byte, error) { return p.k.Bytes() }

func (p *PrivateKey) PublicKey() *PublicKey { return &PublicKey{p.k.PublicKey()} }
