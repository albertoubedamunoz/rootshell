#ifndef CXWING_H
#define CXWING_H

#include <stddef.h>
#include <stdint.h>

// X-Wing hybrid KEM (ML-KEM-768 + X25519, draft-connolly-cfrg-xwing-kem) built
// on the BoringSSL compiled inside swift-crypto's CCryptoBoringSSL. Byte
// layouts match Go's crypto/hpke MLKEM768X25519 (HPKE KEM id 0x647a).

#define CXWING_SEED_BYTES 32
#define CXWING_PUBLIC_KEY_BYTES 1216
#define CXWING_CIPHERTEXT_BYTES 1120
#define CXWING_SHARED_SECRET_BYTES 32

// All functions return 1 on success, 0 on failure.

int cxwing_public_from_seed(uint8_t out_public_key[CXWING_PUBLIC_KEY_BYTES],
                            const uint8_t seed[CXWING_SEED_BYTES]);

int cxwing_encap(uint8_t out_ciphertext[CXWING_CIPHERTEXT_BYTES],
                 uint8_t out_shared_secret[CXWING_SHARED_SECRET_BYTES],
                 const uint8_t public_key[CXWING_PUBLIC_KEY_BYTES]);

int cxwing_decap(uint8_t out_shared_secret[CXWING_SHARED_SECRET_BYTES],
                 const uint8_t ciphertext[CXWING_CIPHERTEXT_BYTES],
                 const uint8_t seed[CXWING_SEED_BYTES]);

#endif
