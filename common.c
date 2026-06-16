
// SPDX-License-Identifier: GPL-3.0-only
/*
 * Copyright (c) 2023 Dengfeng Liu <liudf0716@gmail.com>
 */

#include "uthash.h"
#include "common.h"
#include <stdint.h>

static int is_little_endian(void)
{
	const uint16_t probe = 0x0100;
	return *((const uint8_t *)&probe) == 0;
}

uint64_t ntoh64(const uint64_t input)
{
	if (!is_little_endian()) {
		return input;
	}
#if defined(__GNUC__) || defined(__clang__)
	return __builtin_bswap64(input);
#else
	return ((uint64_t)ntohl((uint32_t)(input & 0xFFFFFFFF)) << 32) |
	       (uint64_t)ntohl((uint32_t)(input >> 32));
#endif
}

uint64_t hton64(const uint64_t input)
{
	return ntoh64(input);
}
