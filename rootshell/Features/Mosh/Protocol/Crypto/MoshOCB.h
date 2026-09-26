//
//  MoshOCB.h
//  rootshell
//
//  AES-128-OCB (RFC 7253) as used by mosh: 96-bit nonce, 128-bit tag,
//  no associated data. ARMv8 AES on Apple silicon, AES-NI on Intel.
//

#ifndef MOSH_OCB_H
#define MOSH_OCB_H

#include <stddef.h>
#include <stdint.h>

#define MOSH_OCB_KEY_LENGTH 16
#define MOSH_OCB_NONCE_LENGTH 12
#define MOSH_OCB_TAG_LENGTH 16

typedef struct mosh_ocb_ctx mosh_ocb_ctx;

/// Returns NULL on allocation failure. The context is immutable after creation.
mosh_ocb_ctx *mosh_ocb_create(const uint8_t key[MOSH_OCB_KEY_LENGTH]);
void mosh_ocb_free(mosh_ocb_ctx *ctx);

/// Writes `length` ciphertext bytes followed by the tag to `out`
/// (`length + MOSH_OCB_TAG_LENGTH` bytes). Returns 0 on success.
int mosh_ocb_encrypt(mosh_ocb_ctx *ctx, const uint8_t nonce[MOSH_OCB_NONCE_LENGTH],
                     const uint8_t *in, size_t length, uint8_t *out);

/// `length` includes the trailing tag. Writes `length - MOSH_OCB_TAG_LENGTH`
/// plaintext bytes to `out`. Returns 0 only if the tag verifies; on failure
/// `out` is zeroed.
int mosh_ocb_decrypt(mosh_ocb_ctx *ctx, const uint8_t nonce[MOSH_OCB_NONCE_LENGTH],
                     const uint8_t *in, size_t length, uint8_t *out);

#endif /* MOSH_OCB_H */
