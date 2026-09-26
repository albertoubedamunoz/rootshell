//
//  MoshOCB.c
//  rootshell
//
//  Clean-room AES-128-OCB from RFC 7253, specialized for mosh (TAGLEN 128,
//  96-bit nonce, empty associated data so HASH(K, A) = 0). The block cipher
//  uses ARMv8 AES on Apple silicon and AES-NI on Intel.
//

#include "MoshOCB.h"

#include <stdlib.h>
#include <string.h>

#define BLOCK 16
#define LANES 4
#define L_COUNT 64

#if defined(__aarch64__)

#if !defined(__ARM_FEATURE_AES)
#error "MoshOCB requires the ARMv8 AES extension"
#endif
#include <arm_neon.h>

typedef uint8x16_t block_t;

static inline block_t block_load(const uint8_t *p) { return vld1q_u8(p); }
static inline void block_store(uint8_t *p, block_t b) { vst1q_u8(p, b); }
static inline block_t block_xor(block_t a, block_t b) { return veorq_u8(a, b); }
static inline block_t block_zero(void) { return vdupq_n_u8(0); }

#elif defined(__x86_64__)

#include <immintrin.h>

// Every Intel Mac supported by macOS 14 has AES-NI; enable it per function
// rather than raising the target's baseline.
#pragma clang attribute push (__attribute__((target("aes,sse4.1"))), apply_to = function)

typedef __m128i block_t;

static inline block_t block_load(const uint8_t *p) { return _mm_loadu_si128((const __m128i *)p); }
static inline void block_store(uint8_t *p, block_t b) { _mm_storeu_si128((__m128i *)p, b); }
static inline block_t block_xor(block_t a, block_t b) { return _mm_xor_si128(a, b); }
static inline block_t block_zero(void) { return _mm_setzero_si128(); }

#else
#error "MoshOCB supports only arm64 and x86_64"
#endif

struct mosh_ocb_ctx {
    block_t enc_keys[11];
    block_t dec_keys[11];
    block_t l_star;
    block_t l_dollar;
    block_t l[L_COUNT];
};

// MARK: - AES-128

#if defined(__aarch64__)

// SubWord via AESE with a zero round key: ShiftRows is a no-op when all four
// columns hold the same word.
static uint32_t sub_word(uint32_t w) {
    uint8x16_t v = vaeseq_u8(vreinterpretq_u8_u32(vdupq_n_u32(w)), vdupq_n_u8(0));
    return vgetq_lane_u32(vreinterpretq_u32_u8(v), 0);
}

static void setup_keys(mosh_ocb_ctx *ctx, const uint8_t key[MOSH_OCB_KEY_LENGTH]) {
    static const uint8_t rcon[10] = { 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36 };
    uint32_t w[44];
    memcpy(w, key, MOSH_OCB_KEY_LENGTH);
    for (int i = 4; i < 44; i++) {
        uint32_t t = w[i - 1];
        if (i % 4 == 0) {
            t = sub_word((t >> 8) | (t << 24)) ^ rcon[i / 4 - 1];
        }
        w[i] = w[i - 4] ^ t;
    }
    for (int r = 0; r < 11; r++) {
        ctx->enc_keys[r] = vld1q_u8((const uint8_t *)&w[r * 4]);
    }
    // Equivalent inverse cipher: reversed schedule, InvMixColumns on the middle keys.
    ctx->dec_keys[0] = ctx->enc_keys[10];
    for (int r = 1; r < 10; r++) {
        ctx->dec_keys[r] = vaesimcq_u8(ctx->enc_keys[10 - r]);
    }
    ctx->dec_keys[10] = ctx->enc_keys[0];
    memset(w, 0, sizeof w);
}

#define ENC_ROUND(s, k) (s) = vaesmcq_u8(vaeseq_u8((s), (k)))
#define ENC_FINAL(s, k9, k10) (s) = veorq_u8(vaeseq_u8((s), (k9)), (k10))
#define DEC_ROUND(s, k) (s) = vaesimcq_u8(vaesdq_u8((s), (k)))
#define DEC_FINAL(s, k9, k10) (s) = veorq_u8(vaesdq_u8((s), (k9)), (k10))

// ARMv8 AESE/AESD fold AddRoundKey in first, so round keys 0-8 drive the loop.
#define CIPHER_LANES(ROUND, FINAL, k, b, n)                                  \
    do {                                                                     \
        if ((n) == LANES) {                                                  \
            block_t s0 = (b)[0], s1 = (b)[1], s2 = (b)[2], s3 = (b)[3];      \
            for (int r = 0; r < 9; r++) {                                    \
                ROUND(s0, (k)[r]); ROUND(s1, (k)[r]);                        \
                ROUND(s2, (k)[r]); ROUND(s3, (k)[r]);                        \
            }                                                                \
            FINAL(s0, (k)[9], (k)[10]); FINAL(s1, (k)[9], (k)[10]);          \
            FINAL(s2, (k)[9], (k)[10]); FINAL(s3, (k)[9], (k)[10]);          \
            (b)[0] = s0; (b)[1] = s1; (b)[2] = s2; (b)[3] = s3;              \
        } else {                                                             \
            for (size_t i = 0; i < (n); i++) {                               \
                block_t s = (b)[i];                                          \
                for (int r = 0; r < 9; r++) ROUND(s, (k)[r]);                \
                FINAL(s, (k)[9], (k)[10]);                                   \
                (b)[i] = s;                                                  \
            }                                                                \
        }                                                                    \
    } while (0)

#else

static __m128i expand_step(__m128i key, __m128i assist) {
    assist = _mm_shuffle_epi32(assist, 0xff);
    key = _mm_xor_si128(key, _mm_slli_si128(key, 4));
    key = _mm_xor_si128(key, _mm_slli_si128(key, 4));
    key = _mm_xor_si128(key, _mm_slli_si128(key, 4));
    return _mm_xor_si128(key, assist);
}

// aeskeygenassist needs its round constant as an immediate.
#define EXPAND(i, rcon) \
    k[i] = expand_step(k[(i) - 1], _mm_aeskeygenassist_si128(k[(i) - 1], (rcon)))

static void setup_keys(mosh_ocb_ctx *ctx, const uint8_t key[MOSH_OCB_KEY_LENGTH]) {
    __m128i *k = ctx->enc_keys;
    k[0] = _mm_loadu_si128((const __m128i *)key);
    EXPAND(1, 0x01); EXPAND(2, 0x02); EXPAND(3, 0x04); EXPAND(4, 0x08); EXPAND(5, 0x10);
    EXPAND(6, 0x20); EXPAND(7, 0x40); EXPAND(8, 0x80); EXPAND(9, 0x1b); EXPAND(10, 0x36);
    ctx->dec_keys[0] = k[10];
    for (int r = 1; r < 10; r++) {
        ctx->dec_keys[r] = _mm_aesimc_si128(k[10 - r]);
    }
    ctx->dec_keys[10] = k[0];
}

#define ENC_ROUND(s, k) (s) = _mm_aesenc_si128((s), (k))
#define ENC_FINAL(s, k) (s) = _mm_aesenclast_si128((s), (k))
#define DEC_ROUND(s, k) (s) = _mm_aesdec_si128((s), (k))
#define DEC_FINAL(s, k) (s) = _mm_aesdeclast_si128((s), (k))

// AES-NI applies the round key last, so key 0 is XORed up front and 1-9 drive the loop.
#define CIPHER_LANES(ROUND, FINAL, k, b, n)                                  \
    do {                                                                     \
        if ((n) == LANES) {                                                  \
            block_t s0 = _mm_xor_si128((b)[0], (k)[0]);                      \
            block_t s1 = _mm_xor_si128((b)[1], (k)[0]);                      \
            block_t s2 = _mm_xor_si128((b)[2], (k)[0]);                      \
            block_t s3 = _mm_xor_si128((b)[3], (k)[0]);                      \
            for (int r = 1; r < 10; r++) {                                   \
                ROUND(s0, (k)[r]); ROUND(s1, (k)[r]);                        \
                ROUND(s2, (k)[r]); ROUND(s3, (k)[r]);                        \
            }                                                                \
            FINAL(s0, (k)[10]); FINAL(s1, (k)[10]);                          \
            FINAL(s2, (k)[10]); FINAL(s3, (k)[10]);                          \
            (b)[0] = s0; (b)[1] = s1; (b)[2] = s2; (b)[3] = s3;              \
        } else {                                                             \
            for (size_t i = 0; i < (n); i++) {                               \
                block_t s = _mm_xor_si128((b)[i], (k)[0]);                   \
                for (int r = 1; r < 10; r++) ROUND(s, (k)[r]);               \
                FINAL(s, (k)[10]);                                           \
                (b)[i] = s;                                                  \
            }                                                                \
        }                                                                    \
    } while (0)

#endif

// Up to LANES independent blocks per call keep the AES pipeline full.
static void encipher(const mosh_ocb_ctx *ctx, block_t *b, size_t n) {
    CIPHER_LANES(ENC_ROUND, ENC_FINAL, ctx->enc_keys, b, n);
}

static void decipher(const mosh_ocb_ctx *ctx, block_t *b, size_t n) {
    CIPHER_LANES(DEC_ROUND, DEC_FINAL, ctx->dec_keys, b, n);
}

// MARK: - OCB

// GF(2^128) doubling on a big-endian block.
static void double_block(uint8_t out[BLOCK], const uint8_t in[BLOCK]) {
    uint8_t carry = in[0] >> 7;
    for (int i = 0; i < BLOCK - 1; i++) {
        out[i] = (uint8_t)((in[i] << 1) | (in[i + 1] >> 7));
    }
    out[BLOCK - 1] = (uint8_t)((in[BLOCK - 1] << 1) ^ (carry * 0x87));
}

mosh_ocb_ctx *mosh_ocb_create(const uint8_t key[MOSH_OCB_KEY_LENGTH]) {
    if (key == NULL) return NULL;
    // block_t needs 16-byte alignment, which malloc guarantees on Apple platforms.
    mosh_ocb_ctx *ctx = calloc(1, sizeof *ctx);
    if (ctx == NULL) return NULL;
    setup_keys(ctx, key);

    block_t star = block_zero();
    encipher(ctx, &star, 1);
    ctx->l_star = star;

    uint8_t cur[BLOCK], next[BLOCK];
    block_store(cur, star);
    double_block(next, cur);
    ctx->l_dollar = block_load(next);
    for (int i = 0; i < L_COUNT; i++) {
        memcpy(cur, next, BLOCK);
        double_block(next, cur);
        ctx->l[i] = block_load(next);
    }
    return ctx;
}

void mosh_ocb_free(mosh_ocb_ctx *ctx) {
    if (ctx == NULL) return;
    memset(ctx, 0, sizeof *ctx);
    free(ctx);
}

static block_t initial_offset(const mosh_ocb_ctx *ctx, const uint8_t nonce[MOSH_OCB_NONCE_LENGTH]) {
    // Nonce = num2str(TAGLEN mod 128, 7) || zeros || 1 || N, with TAGLEN = 128.
    uint8_t n[BLOCK] = { 0, 0, 0, 1 };
    memcpy(n + 4, nonce, MOSH_OCB_NONCE_LENGTH);
    unsigned bottom = n[BLOCK - 1] & 0x3f;
    n[BLOCK - 1] &= 0xc0;

    block_t ktop = block_load(n);
    encipher(ctx, &ktop, 1);

    uint8_t stretch[BLOCK + 9];
    block_store(stretch, ktop);
    for (int i = 0; i < 8; i++) {
        stretch[BLOCK + i] = stretch[i] ^ stretch[i + 1];
    }
    stretch[BLOCK + 8] = 0;

    unsigned bytes = bottom / 8, bits = bottom % 8;
    uint8_t out[BLOCK];
    for (int i = 0; i < BLOCK; i++) {
        out[i] = bits == 0
            ? stretch[i + bytes]
            : (uint8_t)((stretch[i + bytes] << bits) | (stretch[i + bytes + 1] >> (8 - bits)));
    }
    return block_load(out);
}

static inline block_t next_offset(const mosh_ocb_ctx *ctx, block_t offset, size_t index) {
    return block_xor(offset, ctx->l[__builtin_ctzll((unsigned long long)index)]);
}

static block_t final_tag(const mosh_ocb_ctx *ctx, block_t checksum, block_t offset) {
    block_t tag = block_xor(block_xor(checksum, offset), ctx->l_dollar);
    encipher(ctx, &tag, 1);
    return tag;
}

int mosh_ocb_encrypt(mosh_ocb_ctx *ctx, const uint8_t nonce[MOSH_OCB_NONCE_LENGTH],
                     const uint8_t *in, size_t length, uint8_t *out) {
    if (ctx == NULL || nonce == NULL || out == NULL || (in == NULL && length > 0)) return -1;

    block_t offset = initial_offset(ctx, nonce), checksum = block_zero();
    size_t full = length / BLOCK, i = 0;
    block_t x[LANES], o[LANES];
    while (i < full) {
        size_t n = full - i < LANES ? full - i : LANES;
        for (size_t k = 0; k < n; k++) {
            offset = next_offset(ctx, offset, i + k + 1);
            block_t p = block_load(in + (i + k) * BLOCK);
            checksum = block_xor(checksum, p);
            o[k] = offset;
            x[k] = block_xor(p, offset);
        }
        encipher(ctx, x, n);
        for (size_t k = 0; k < n; k++) {
            block_store(out + (i + k) * BLOCK, block_xor(x[k], o[k]));
        }
        i += n;
    }

    size_t rem = length % BLOCK;
    if (rem > 0) {
        offset = block_xor(offset, ctx->l_star);
        block_t pad = offset;
        encipher(ctx, &pad, 1);
        uint8_t padded[BLOCK] = { 0 }, pad_bytes[BLOCK];
        memcpy(padded, in + full * BLOCK, rem);
        padded[rem] = 0x80;
        checksum = block_xor(checksum, block_load(padded));
        block_store(pad_bytes, pad);
        for (size_t j = 0; j < rem; j++) {
            out[full * BLOCK + j] = padded[j] ^ pad_bytes[j];
        }
    }

    block_store(out + length, final_tag(ctx, checksum, offset));
    return 0;
}

int mosh_ocb_decrypt(mosh_ocb_ctx *ctx, const uint8_t nonce[MOSH_OCB_NONCE_LENGTH],
                     const uint8_t *in, size_t length, uint8_t *out) {
    if (ctx == NULL || nonce == NULL || in == NULL || length < MOSH_OCB_TAG_LENGTH) return -1;
    size_t plain_length = length - MOSH_OCB_TAG_LENGTH;
    if (out == NULL && plain_length > 0) return -1;

    block_t offset = initial_offset(ctx, nonce), checksum = block_zero();
    size_t full = plain_length / BLOCK, i = 0;
    block_t x[LANES], o[LANES];
    while (i < full) {
        size_t n = full - i < LANES ? full - i : LANES;
        for (size_t k = 0; k < n; k++) {
            offset = next_offset(ctx, offset, i + k + 1);
            o[k] = offset;
            x[k] = block_xor(block_load(in + (i + k) * BLOCK), offset);
        }
        decipher(ctx, x, n);
        for (size_t k = 0; k < n; k++) {
            block_t p = block_xor(x[k], o[k]);
            checksum = block_xor(checksum, p);
            block_store(out + (i + k) * BLOCK, p);
        }
        i += n;
    }

    size_t rem = plain_length % BLOCK;
    if (rem > 0) {
        offset = block_xor(offset, ctx->l_star);
        block_t pad = offset;
        encipher(ctx, &pad, 1);
        uint8_t padded[BLOCK] = { 0 }, pad_bytes[BLOCK];
        block_store(pad_bytes, pad);
        for (size_t j = 0; j < rem; j++) {
            padded[j] = in[full * BLOCK + j] ^ pad_bytes[j];
        }
        memcpy(out + full * BLOCK, padded, rem);
        padded[rem] = 0x80;
        checksum = block_xor(checksum, block_load(padded));
    }

    uint8_t expected[BLOCK], diff = 0;
    block_store(expected, final_tag(ctx, checksum, offset));
    for (int j = 0; j < BLOCK; j++) {
        diff |= expected[j] ^ in[plain_length + j];
    }
    if (diff != 0) {
        if (plain_length > 0) memset(out, 0, plain_length);
        return -1;
    }
    return 0;
}

#if defined(__x86_64__)
#pragma clang attribute pop
#endif
