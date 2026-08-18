#include "CrocXXHash.h"

#include <string.h>

#define CROC_XXH_PRIME64_1 0x9E3779B185EBCA87ULL
#define CROC_XXH_PRIME64_2 0xC2B2AE3D27D4EB4FULL
#define CROC_XXH_PRIME64_3 0x165667B19E3779F9ULL
#define CROC_XXH_PRIME64_4 0x85EBCA77C2B2AE63ULL
#define CROC_XXH_PRIME64_5 0x27D4EB2F165667C5ULL

static inline uint64_t croc_xxh_rotl64(uint64_t value, int count) {
    return (value << count) | (value >> (64 - count));
}

static inline uint64_t croc_xxh_read64(const uint8_t *ptr) {
    uint64_t value;
    memcpy(&value, ptr, sizeof(value));
#if __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
    value = __builtin_bswap64(value);
#endif
    return value;
}

static inline uint32_t croc_xxh_read32(const uint8_t *ptr) {
    uint32_t value;
    memcpy(&value, ptr, sizeof(value));
#if __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
    value = __builtin_bswap32(value);
#endif
    return value;
}

static inline uint64_t croc_xxh_round(uint64_t acc, uint64_t input) {
    acc += input * CROC_XXH_PRIME64_2;
    acc = croc_xxh_rotl64(acc, 31);
    acc *= CROC_XXH_PRIME64_1;
    return acc;
}

static inline uint64_t croc_xxh_merge_round(uint64_t acc, uint64_t value) {
    value = croc_xxh_round(0, value);
    acc ^= value;
    acc = acc * CROC_XXH_PRIME64_1 + CROC_XXH_PRIME64_4;
    return acc;
}

uint64_t croc_xxhash64(const void *input, size_t length) {
    const uint8_t *ptr = (const uint8_t *)input;
    const uint8_t *end = ptr != NULL ? ptr + length : NULL;
    uint64_t hash;

    if (length >= 32 && ptr != NULL) {
        const uint8_t *limit = end - 32;
        uint64_t v1 = CROC_XXH_PRIME64_1 + CROC_XXH_PRIME64_2;
        uint64_t v2 = CROC_XXH_PRIME64_2;
        uint64_t v3 = 0;
        uint64_t v4 = 0 - CROC_XXH_PRIME64_1;

        do {
            v1 = croc_xxh_round(v1, croc_xxh_read64(ptr));
            ptr += 8;
            v2 = croc_xxh_round(v2, croc_xxh_read64(ptr));
            ptr += 8;
            v3 = croc_xxh_round(v3, croc_xxh_read64(ptr));
            ptr += 8;
            v4 = croc_xxh_round(v4, croc_xxh_read64(ptr));
            ptr += 8;
        } while (ptr <= limit);

        hash = croc_xxh_rotl64(v1, 1) + croc_xxh_rotl64(v2, 7) + croc_xxh_rotl64(v3, 12) + croc_xxh_rotl64(v4, 18);
        hash = croc_xxh_merge_round(hash, v1);
        hash = croc_xxh_merge_round(hash, v2);
        hash = croc_xxh_merge_round(hash, v3);
        hash = croc_xxh_merge_round(hash, v4);
    } else {
        hash = CROC_XXH_PRIME64_5;
    }

    hash += (uint64_t)length;

    if (ptr != NULL) {
        while (ptr + 8 <= end) {
            uint64_t k1 = croc_xxh_round(0, croc_xxh_read64(ptr));
            ptr += 8;
            hash ^= k1;
            hash = croc_xxh_rotl64(hash, 27) * CROC_XXH_PRIME64_1 + CROC_XXH_PRIME64_4;
        }

        if (ptr + 4 <= end) {
            hash ^= (uint64_t)croc_xxh_read32(ptr) * CROC_XXH_PRIME64_1;
            ptr += 4;
            hash = croc_xxh_rotl64(hash, 23) * CROC_XXH_PRIME64_2 + CROC_XXH_PRIME64_3;
        }

        while (ptr < end) {
            hash ^= (uint64_t)(*ptr) * CROC_XXH_PRIME64_5;
            ptr += 1;
            hash = croc_xxh_rotl64(hash, 11) * CROC_XXH_PRIME64_1;
        }
    }

    hash ^= hash >> 33;
    hash *= CROC_XXH_PRIME64_2;
    hash ^= hash >> 29;
    hash *= CROC_XXH_PRIME64_3;
    hash ^= hash >> 32;

    return hash;
}
