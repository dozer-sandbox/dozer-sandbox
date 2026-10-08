/*
 * dozre.h — PRIVATE to the DozMatch target: the RE2-subset regexp engine behind dozmatch.c, and the
 * shared strict UTF-8 decoder. Not part of the public contract (include/dozmatch.h).
 *
 * The engine accepts the RE2 (Go regexp/syntax, Perl flags) language that patternmatcher's
 * Pattern.compile can emit, with RE2's parse errors; matching is Go's MatchString (unanchored search,
 * by UTF-8 rune, an invalid byte being one U+FFFD rune). It is a Thompson-NFA / Pike-VM set
 * simulation: O(len(path) x len(program)) whatever the pattern, so `**` chains cannot blow up.
 * A compiled program is immutable; matching uses per-call scratch only (stack, or malloc when big).
 * LICENCE: the engine (dozre.c) is a port of Go's regexp/syntax — BSD-3-Clause, Copyright 2009 The Go
 * Authors; the full text is in dozre.c's header and Licences/go-go1.25.0.LICENSE.
 */
#ifndef DOZRE_H
#define DOZRE_H

#include <stddef.h>
#include <stdint.h>

typedef struct dmre dmre;

#define DMRE_OK       0
#define DMRE_ESYNTAX (-1)   /* RE2 would refuse the expression */
#define DMRE_ENOMEM  (-2)

/* Compile `re` (len bytes, any content). DMRE_OK / DMRE_ESYNTAX / DMRE_ENOMEM. */
int dmre_compile(const char *re, size_t len, dmre **out);
/* 1 match, 0 no match, DMRE_ENOMEM when scratch could not be allocated. Thread-safe on a shared dmre. */
int dmre_match(const dmre *r, const char *s, size_t len);
void dmre_free(dmre *r);

/* Go utf8.DecodeRune: strict (no overlongs, surrogates or > U+10FFFF); an invalid or truncated
 * sequence is (U+FFFD, 1). n must be > 0. */
uint32_t dm__utf8_decode(const unsigned char *s, size_t n, size_t *width);
/* Encode a scalar (<= 0x10FFFF, not a surrogate) into buf (>= 4 bytes); returns the byte count. */
size_t dm__utf8_encode(uint32_t r, unsigned char *buf);

#endif
