// Prototypes mirror swift-crypto 3.15.1's vendored mlkem.h, curve25519.h,
// bytestring.h and keccak/internal.h with the CCryptoBoringSSL_ symbol prefix.
// Key structs are opaque here; storage is over-allocated (real sizes 7,776 and
// 6,208 bytes) so a moderate upstream growth cannot overflow.

#include "include/cxwing.h"

#include <string.h>

#define MLKEM768_PUBLIC_KEY_BYTES 1184
#define MLKEM768_CIPHERTEXT_BYTES 1088
#define MLKEM_SEED_BYTES 64
#define X25519_BYTES 32

#define PRIVATE_KEY_STORAGE 16384
#define PUBLIC_KEY_STORAGE 8192

struct MLKEM768_private_key;
struct MLKEM768_public_key;

typedef struct cbs_st {
  const uint8_t *data;
  size_t len;
} CBS;

typedef struct cxwing_opaque_cbb {
  uint8_t opaque[512] __attribute__((aligned(16)));
} OPAQUE_CBB;

enum boringssl_keccak_config_t { boringssl_sha3_256 = 0, boringssl_shake256 = 3 };

extern int CCryptoBoringSSL_MLKEM768_private_key_from_seed(
    struct MLKEM768_private_key *out_private_key, const uint8_t *seed,
    size_t seed_len);
extern void CCryptoBoringSSL_MLKEM768_public_from_private(
    struct MLKEM768_public_key *out_public_key,
    const struct MLKEM768_private_key *private_key);
extern void CCryptoBoringSSL_MLKEM768_encap(
    uint8_t out_ciphertext[MLKEM768_CIPHERTEXT_BYTES],
    uint8_t out_shared_secret[32],
    const struct MLKEM768_public_key *public_key);
extern int CCryptoBoringSSL_MLKEM768_decap(
    uint8_t out_shared_secret[32], const uint8_t *ciphertext,
    size_t ciphertext_len, const struct MLKEM768_private_key *private_key);
extern int CCryptoBoringSSL_MLKEM768_marshal_public_key(
    void *out_cbb, const struct MLKEM768_public_key *public_key);
extern int CCryptoBoringSSL_MLKEM768_parse_public_key(
    struct MLKEM768_public_key *out_public_key, CBS *in);
extern int CCryptoBoringSSL_CBB_init_fixed(void *cbb, uint8_t *buf, size_t len);
extern size_t CCryptoBoringSSL_CBB_len(const void *cbb);
extern void CCryptoBoringSSL_X25519_keypair(uint8_t out_public_value[32],
                                            uint8_t out_private_key[32]);
extern int CCryptoBoringSSL_X25519(uint8_t out_shared_key[32],
                                   const uint8_t private_key[32],
                                   const uint8_t peer_public_value[32]);
extern void CCryptoBoringSSL_X25519_public_from_private(
    uint8_t out_public_value[32], const uint8_t private_key[32]);
extern void CCryptoBoringSSL_BORINGSSL_keccak(uint8_t *out, size_t out_len,
                                              const uint8_t *in, size_t in_len,
                                              int config);
extern void CCryptoBoringSSL_OPENSSL_cleanse(void *ptr, size_t len);

static const uint8_t kXWingLabel[6] = {'\\', '.', '/', '/', '^', '\\'};

// seed -> SHAKE256 -> ML-KEM seed (64) || X25519 private key (32).
static int expand_seed(const uint8_t seed[CXWING_SEED_BYTES],
                       struct MLKEM768_private_key *mlkem_priv,
                       uint8_t x25519_priv[X25519_BYTES]) {
  uint8_t expanded[MLKEM_SEED_BYTES + X25519_BYTES];
  CCryptoBoringSSL_BORINGSSL_keccak(expanded, sizeof(expanded), seed,
                                    CXWING_SEED_BYTES, boringssl_shake256);
  int ok = CCryptoBoringSSL_MLKEM768_private_key_from_seed(mlkem_priv, expanded,
                                                           MLKEM_SEED_BYTES);
  memcpy(x25519_priv, expanded + MLKEM_SEED_BYTES, X25519_BYTES);
  CCryptoBoringSSL_OPENSSL_cleanse(expanded, sizeof(expanded));
  return ok;
}

static void combine(uint8_t out[CXWING_SHARED_SECRET_BYTES],
                    const uint8_t ss_m[32], const uint8_t ss_x[32],
                    const uint8_t ct_x[32], const uint8_t pk_x[32]) {
  uint8_t in[32 + 32 + 32 + 32 + sizeof(kXWingLabel)];
  memcpy(in, ss_m, 32);
  memcpy(in + 32, ss_x, 32);
  memcpy(in + 64, ct_x, 32);
  memcpy(in + 96, pk_x, 32);
  memcpy(in + 128, kXWingLabel, sizeof(kXWingLabel));
  CCryptoBoringSSL_BORINGSSL_keccak(out, CXWING_SHARED_SECRET_BYTES, in,
                                    sizeof(in), boringssl_sha3_256);
  CCryptoBoringSSL_OPENSSL_cleanse(in, sizeof(in));
}

int cxwing_public_from_seed(uint8_t out_public_key[CXWING_PUBLIC_KEY_BYTES],
                            const uint8_t seed[CXWING_SEED_BYTES]) {
  uint8_t priv_storage[PRIVATE_KEY_STORAGE] __attribute__((aligned(16)));
  uint8_t pub_storage[PUBLIC_KEY_STORAGE] __attribute__((aligned(16)));
  struct MLKEM768_private_key *priv = (struct MLKEM768_private_key *)priv_storage;
  struct MLKEM768_public_key *pub = (struct MLKEM768_public_key *)pub_storage;
  uint8_t x_priv[X25519_BYTES];
  OPAQUE_CBB cbb;
  int ok = 0;

  if (!expand_seed(seed, priv, x_priv)) {
    goto out;
  }
  CCryptoBoringSSL_MLKEM768_public_from_private(pub, priv);
  if (!CCryptoBoringSSL_CBB_init_fixed(&cbb, out_public_key,
                                       MLKEM768_PUBLIC_KEY_BYTES) ||
      !CCryptoBoringSSL_MLKEM768_marshal_public_key(&cbb, pub) ||
      CCryptoBoringSSL_CBB_len(&cbb) != MLKEM768_PUBLIC_KEY_BYTES) {
    goto out;
  }
  CCryptoBoringSSL_X25519_public_from_private(
      out_public_key + MLKEM768_PUBLIC_KEY_BYTES, x_priv);
  ok = 1;

out:
  CCryptoBoringSSL_OPENSSL_cleanse(priv_storage, sizeof(priv_storage));
  CCryptoBoringSSL_OPENSSL_cleanse(x_priv, sizeof(x_priv));
  return ok;
}

int cxwing_encap(uint8_t out_ciphertext[CXWING_CIPHERTEXT_BYTES],
                 uint8_t out_shared_secret[CXWING_SHARED_SECRET_BYTES],
                 const uint8_t public_key[CXWING_PUBLIC_KEY_BYTES]) {
  uint8_t pub_storage[PUBLIC_KEY_STORAGE] __attribute__((aligned(16)));
  struct MLKEM768_public_key *pub = (struct MLKEM768_public_key *)pub_storage;
  CBS cbs = {public_key, MLKEM768_PUBLIC_KEY_BYTES};
  const uint8_t *pk_x = public_key + MLKEM768_PUBLIC_KEY_BYTES;
  uint8_t *ct_x = out_ciphertext + MLKEM768_CIPHERTEXT_BYTES;
  uint8_t ek_x[X25519_BYTES], ss_m[32], ss_x[32];
  int ok = 0;

  if (!CCryptoBoringSSL_MLKEM768_parse_public_key(pub, &cbs) || cbs.len != 0) {
    return 0;
  }
  CCryptoBoringSSL_X25519_keypair(ct_x, ek_x);
  if (!CCryptoBoringSSL_X25519(ss_x, ek_x, pk_x)) {
    goto out;
  }
  CCryptoBoringSSL_MLKEM768_encap(out_ciphertext, ss_m, pub);
  combine(out_shared_secret, ss_m, ss_x, ct_x, pk_x);
  ok = 1;

out:
  CCryptoBoringSSL_OPENSSL_cleanse(ek_x, sizeof(ek_x));
  CCryptoBoringSSL_OPENSSL_cleanse(ss_m, sizeof(ss_m));
  CCryptoBoringSSL_OPENSSL_cleanse(ss_x, sizeof(ss_x));
  return ok;
}

int cxwing_decap(uint8_t out_shared_secret[CXWING_SHARED_SECRET_BYTES],
                 const uint8_t ciphertext[CXWING_CIPHERTEXT_BYTES],
                 const uint8_t seed[CXWING_SEED_BYTES]) {
  uint8_t priv_storage[PRIVATE_KEY_STORAGE] __attribute__((aligned(16)));
  struct MLKEM768_private_key *priv = (struct MLKEM768_private_key *)priv_storage;
  const uint8_t *ct_x = ciphertext + MLKEM768_CIPHERTEXT_BYTES;
  uint8_t x_priv[X25519_BYTES], pk_x[X25519_BYTES], ss_m[32], ss_x[32];
  int ok = 0;

  if (!expand_seed(seed, priv, x_priv)) {
    goto out;
  }
  if (!CCryptoBoringSSL_MLKEM768_decap(ss_m, ciphertext,
                                       MLKEM768_CIPHERTEXT_BYTES, priv)) {
    goto out;
  }
  if (!CCryptoBoringSSL_X25519(ss_x, x_priv, ct_x)) {
    goto out;
  }
  CCryptoBoringSSL_X25519_public_from_private(pk_x, x_priv);
  combine(out_shared_secret, ss_m, ss_x, ct_x, pk_x);
  ok = 1;

out:
  CCryptoBoringSSL_OPENSSL_cleanse(priv_storage, sizeof(priv_storage));
  CCryptoBoringSSL_OPENSSL_cleanse(x_priv, sizeof(x_priv));
  CCryptoBoringSSL_OPENSSL_cleanse(ss_m, sizeof(ss_m));
  CCryptoBoringSSL_OPENSSL_cleanse(ss_x, sizeof(ss_x));
  return ok;
}
