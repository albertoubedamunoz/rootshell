#ifndef CROC_XXHASH_H
#define CROC_XXHASH_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

uint64_t croc_xxhash64(const void *input, size_t length);

#ifdef __cplusplus
}
#endif

#endif
