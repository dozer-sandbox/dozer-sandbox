/*
 * dozre.c — the RE2-subset regexp engine (see dozre.h). Ports, behaviour for behaviour, the parts of
 * Go's regexp/syntax parser (flags = syntax.Perl: ClassNL | OneLine | PerlX | UnicodeGroups) that
 * patternmatcher's Pattern.compile output can reach:
 *   - literals, `.` (not \n), `^` / `\A` (begin of text), `$` / `\z` (end of text: OneLine),
 *     `\b` `\B` (ASCII word boundary), groups `( )`, `|`, `* + ?` (+ the non-greedy `?` suffix),
 *     with RE2's "missing argument" and "invalid nested repetition" errors;
 *   - classes `[...]`: `^` negation (matches \n: ClassNL), a leading `]` literal, ranges (inverted =
 *     error), escapes, `[:name:]` / `[:^name:]` POSIX groups (unknown name = error, the `:]` searched
 *     to the end of the expression exactly as Go does), `\d \s \w \D \S \W`;
 *   - escapes: punctuation -> itself, \a \f \n \r \t \v, octal (\0.., \1-\7 + an octal digit),
 *     \xHH / \x{H..}, \Q...\E; anything else alphanumeric or non-ASCII is an error.
 * NOT supported (reported as a syntax error, so a pattern using them never matches in lenient mode):
 * `\pX` / `\p{Name}` Unicode classes (RE2 accepts the valid names), `(?flags)` groups and `{n,m}`
 * counted repetition — compile() escapes `(` and `{`, so neither can reach here except through \p.
 *
 * LICENCE: this file is a port (translated to C, then cut down to the subset above) of Go's regexp/syntax
 * parser and regexp's matcher, and is distributed under Go's BSD-3-Clause licence, reproduced here
 * (also in Licences/go-go1.25.0.LICENSE and in every release's THIRD-PARTY-LICENSES.txt):
 *
 * Copyright 2009 The Go Authors.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are
 * met:
 *
 *    * Redistributions of source code must retain the above copyright
 * notice, this list of conditions and the following disclaimer.
 *    * Redistributions in binary form must reproduce the above
 * copyright notice, this list of conditions and the following disclaimer
 * in the documentation and/or other materials provided with the
 * distribution.
 *    * Neither the name of Google LLC nor the names of its
 * contributors may be used to endorse or promote products derived from
 * this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 * OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 * LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */
#include "dozre.h"

#include <stdlib.h>
#include <string.h>

/* ---------------------------------------------------------------- UTF-8 */

uint32_t dm__utf8_decode(const unsigned char *s, size_t n, size_t *width) {
    unsigned char b0 = s[0];
    if (b0 < 0x80) { *width = 1; return b0; }
    unsigned char lo = 0x80, hi = 0xBF;
    size_t need;
    uint32_t r;
    if (b0 >= 0xC2 && b0 <= 0xDF) { need = 2; r = b0 & 0x1F; }
    else if (b0 >= 0xE0 && b0 <= 0xEF) {
        need = 3; r = b0 & 0x0F;
        if (b0 == 0xE0) lo = 0xA0;
        else if (b0 == 0xED) hi = 0x9F;
    } else if (b0 >= 0xF0 && b0 <= 0xF4) {
        need = 4; r = b0 & 0x07;
        if (b0 == 0xF0) lo = 0x90;
        else if (b0 == 0xF4) hi = 0x8F;
    } else { *width = 1; return 0xFFFD; }
    if (n < 2 || s[1] < lo || s[1] > hi) { *width = 1; return 0xFFFD; }
    r = (r << 6) | (s[1] & 0x3F);
    for (size_t i = 2; i < need; i++) {
        if (i >= n || s[i] < 0x80 || s[i] > 0xBF) { *width = 1; return 0xFFFD; }
        r = (r << 6) | (s[i] & 0x3F);
    }
    *width = need;
    return r;
}

size_t dm__utf8_encode(uint32_t r, unsigned char *b) {
    if (r < 0x80) { b[0] = (unsigned char)r; return 1; }
    if (r < 0x800) { b[0] = (unsigned char)(0xC0 | (r >> 6)); b[1] = (unsigned char)(0x80 | (r & 0x3F)); return 2; }
    if (r < 0x10000) {
        b[0] = (unsigned char)(0xE0 | (r >> 12)); b[1] = (unsigned char)(0x80 | ((r >> 6) & 0x3F));
        b[2] = (unsigned char)(0x80 | (r & 0x3F)); return 3;
    }
    b[0] = (unsigned char)(0xF0 | (r >> 18)); b[1] = (unsigned char)(0x80 | ((r >> 12) & 0x3F));
    b[2] = (unsigned char)(0x80 | ((r >> 6) & 0x3F)); b[3] = (unsigned char)(0x80 | (r & 0x3F)); return 4;
}

/* ---------------------------------------------------------------- AST */

enum { N_LIT, N_CLASS, N_ANY, N_BOT, N_EOT, N_WB, N_NWB, N_EMPTY, N_CAT, N_ALT, N_STAR, N_PLUS, N_QUEST,
       N_REPEAT, N_CAPTURE };

/* kid/last: first/last child; next: sibling; min/max: N_REPEAT's bounds (max -1 = unbounded) */
typedef struct { int op; uint32_t v; int kid, last, next; int min, max, height; int64_t size; } node;
typedef struct { int start, count, neg; } cclass; /* count lo,hi pairs from ranges[start] (start in uint32s) */

enum { I_RUNE, I_CLASS, I_ANY, I_ASSERT, I_SPLIT, I_JMP, I_MATCH };
typedef struct { int op; uint32_t arg; int x, y; } inst;

struct dmre {
    inst *prog; int ninst;
    uint32_t *ranges; cclass *classes;
    int anchored; /* prog[0] is a begin-of-text assertion: only try position 0 */
    /* Prefilter, exact: a top-level concatenation ^ L1..Lk ... M1..Mj $ can only match a text that starts
     * with L1..Lk and ends with M1..Mj (UTF-8 bytes; U+FFFD, which also matches an invalid byte, ends a run). */
    unsigned char *pre, *suf;
    size_t npre, nsuf;
};

typedef struct {
    const unsigned char *s; size_t n, i;
    node *nodes; int nn, ncap;
    uint32_t *ranges; int nr, rcap;  /* counts in uint32s */
    cclass *classes; int nc, ccap;
    int depth;
    int err; /* DMRE_* */
} parser;

static int grow(void **p, int *cap, int need, size_t elem) {
    if (need <= *cap) return 1;
    int nc = *cap ? *cap : 16;
    while (nc < need) nc *= 2;
    void *q = realloc(*p, (size_t)nc * elem);
    if (!q) return 0;
    *p = q; *cap = nc;
    return 1;
}

static int new_node(parser *P, int op, uint32_t v) {
    if (!grow((void **)&P->nodes, &P->ncap, P->nn + 1, sizeof(node))) { P->err = DMRE_ENOMEM; return -1; }
    node *n = &P->nodes[P->nn];
    n->op = op; n->v = v; n->kid = n->last = n->next = -1; n->min = n->max = 0;
    n->height = 1; n->size = 1;
    return P->nn++;
}

static void add_kid(parser *P, int parent, int kid) {
    node *p = &P->nodes[parent];
    if (p->kid < 0) p->kid = kid; else P->nodes[p->last].next = kid;
    p->last = kid;
}

/* Go's parser limits (checkSize / checkHeight): maxSize = 128 MiB / 40 B "instructions", nesting 1000.
 * Sizes follow calcSize (literal runs and single-character alternations are counted unmerged here,
 * so only an expression within a few percent of the limit could be judged differently). */
#define GO_MAX_SIZE ((int64_t)(128 << 20) / 40)
#define GO_MAX_HEIGHT 1000

static int finish_node(parser *P, int k) {
    node *n = &P->nodes[k];
    int h = 1, all_lit = 1;
    int64_t sum = 0, sub = 0;
    int kids = 0;
    for (int c = n->kid; c >= 0; c = P->nodes[c].next) {
        const node *cn = &P->nodes[c];
        if (1 + cn->height > h) h = 1 + cn->height;
        if (cn->op != N_LIT) all_lit = 0;
        sum += cn->size;
        sub = cn->size;
        kids++;
    }
    int64_t size;
    switch (n->op) {
    case N_CAT: size = sum; if (all_lit) h = 1; break;  /* Go merges a literal run into one node */
    case N_ALT: size = sum + (kids > 1 ? kids - 1 : 0); break;
    case N_STAR: case N_CAPTURE: size = 2 + sub; break;
    case N_PLUS: case N_QUEST: size = 1 + sub; break;
    case N_REPEAT:
        if (n->max == -1) size = n->min == 0 ? 2 + sub : 1 + (int64_t)n->min * sub;
        else size = (int64_t)n->max * sub + (n->max - n->min);
        break;
    default: size = 1; break;
    }
    if (size < 1) size = 1;
    n->height = h;
    n->size = size;
    if (size > GO_MAX_SIZE || h > GO_MAX_HEIGHT) { P->err = DMRE_ESYNTAX; return 0; }
    return 1;
}

static int add_range(parser *P, uint32_t lo, uint32_t hi) {
    if (!grow((void **)&P->ranges, &P->rcap, P->nr + 2, sizeof(uint32_t))) { P->err = DMRE_ENOMEM; return 0; }
    P->ranges[P->nr++] = lo; P->ranges[P->nr++] = hi;
    return 1;
}

/* Append group g (sorted lo,hi pairs) or its complement over [0, 0x10FFFF]. */
static int add_group(parser *P, const uint32_t *g, int npairs, int negate) {
    if (!negate) {
        for (int k = 0; k < npairs; k++) if (!add_range(P, g[2 * k], g[2 * k + 1])) return 0;
        return 1;
    }
    uint32_t next = 0;
    for (int k = 0; k < npairs; k++) {
        if (g[2 * k] > next && !add_range(P, next, g[2 * k] - 1)) return 0;
        next = g[2 * k + 1] + 1;
    }
    if (next <= 0x10FFFF && !add_range(P, next, 0x10FFFF)) return 0;
    return 1;
}

static const uint32_t G_D[] = { 0x30, 0x39 };
static const uint32_t G_S[] = { 0x9, 0xa, 0xc, 0xd, 0x20, 0x20 };
static const uint32_t G_W[] = { 0x30, 0x39, 0x41, 0x5a, 0x5f, 0x5f, 0x61, 0x7a };

static const struct { const char *name; uint32_t g[8]; int npairs; } POSIX[] = {
    { "alnum", { 0x30, 0x39, 0x41, 0x5a, 0x61, 0x7a }, 3 },
    { "alpha", { 0x41, 0x5a, 0x61, 0x7a }, 2 },
    { "ascii", { 0x0, 0x7f }, 1 },
    { "blank", { 0x9, 0x9, 0x20, 0x20 }, 2 },
    { "cntrl", { 0x0, 0x1f, 0x7f, 0x7f }, 2 },
    { "digit", { 0x30, 0x39 }, 1 },
    { "graph", { 0x21, 0x7e }, 1 },
    { "lower", { 0x61, 0x7a }, 1 },
    { "print", { 0x20, 0x7e }, 1 },
    { "punct", { 0x21, 0x2f, 0x3a, 0x40, 0x5b, 0x60, 0x7b, 0x7e }, 4 },
    { "space", { 0x9, 0xd, 0x20, 0x20 }, 2 },
    { "upper", { 0x41, 0x5a }, 1 },
    { "word", { 0x30, 0x39, 0x41, 0x5a, 0x5f, 0x5f, 0x61, 0x7a }, 4 },
    { "xdigit", { 0x30, 0x39, 0x41, 0x46, 0x61, 0x66 }, 3 },
};

/* If s[i..] starts a Perl class escape (\d \D \s \S \w \W), append it, advance, return 1. */
static int perl_class(parser *P) {
    if (P->i + 1 >= P->n || P->s[P->i] != '\\') return 0;
    unsigned char c = P->s[P->i + 1];
    const uint32_t *g; int np, neg;
    switch (c) {
    case 'd': case 'D': g = G_D; np = 1; break;
    case 's': case 'S': g = G_S; np = 3; break;
    case 'w': case 'W': g = G_W; np = 4; break;
    default: return 0;
    }
    neg = (c == 'D' || c == 'S' || c == 'W');
    P->i += 2;
    add_group(P, g, np, neg);
    return 1;
}

static int isalnum_ascii(uint32_t c) {
    return (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
}

static int unhex(uint32_t c) {
    if (c >= '0' && c <= '9') return (int)(c - '0');
    if (c >= 'a' && c <= 'f') return (int)(c - 'a' + 10);
    if (c >= 'A' && c <= 'F') return (int)(c - 'A' + 10);
    return -1;
}

/* Go nextRune: decode, an invalid sequence is ErrInvalidUTF8. At end, Go yields (RuneError, "") with no
 * error; callers here treat that as a value that fails every check (*at_end = 1). */
static int next_rune(parser *P, uint32_t *r) {
    if (P->i >= P->n) { *r = 0xFFFFFFFFu; return 1; }
    size_t w;
    *r = dm__utf8_decode(P->s + P->i, P->n - P->i, &w);
    if (*r == 0xFFFD && w == 1) { P->err = DMRE_ESYNTAX; return 0; }
    P->i += w;
    return 1;
}

/* Go parser.parseEscape at s[i] == '\\'. */
static int parse_escape(parser *P, uint32_t *out) {
    P->i++;
    if (P->i >= P->n) { P->err = DMRE_ESYNTAX; return 0; } /* trailing backslash */
    uint32_t c;
    if (!next_rune(P, &c)) return 0;
    switch (c) {
    case '1': case '2': case '3': case '4': case '5': case '6': case '7':
        if (P->i >= P->n || P->s[P->i] < '0' || P->s[P->i] > '7') break; /* backreference: unsupported */
        /* fallthrough */
    case '0': {
        uint32_t r = c - '0';
        for (int k = 1; k < 3; k++) {
            if (P->i >= P->n || P->s[P->i] < '0' || P->s[P->i] > '7') break;
            r = r * 8 + (uint32_t)(P->s[P->i] - '0');
            P->i++;
        }
        *out = r;
        return 1;
    }
    case 'x': {
        if (P->i >= P->n) break;
        if (!next_rune(P, &c)) return 0;
        if (c == '{') {
            int nhex = 0;
            uint32_t r = 0;
            for (;;) {
                if (P->i >= P->n) goto bad;
                if (!next_rune(P, &c)) return 0;
                if (c == '}') break;
                int v = unhex(c);
                if (v < 0) goto bad;
                r = r * 16 + (uint32_t)v;
                if (r > 0x10FFFF) goto bad;
                nhex++;
            }
            if (nhex == 0) goto bad;
            *out = r;
            return 1;
        }
        int x = unhex(c);
        if (!next_rune(P, &c)) return 0;
        int y = unhex(c);
        if (x < 0 || y < 0) break;
        *out = (uint32_t)(x * 16 + y);
        return 1;
    }
    case 'a': *out = 7; return 1;
    case 'f': *out = 12; return 1;
    case 'n': *out = 10; return 1;
    case 'r': *out = 13; return 1;
    case 't': *out = 9; return 1;
    case 'v': *out = 11; return 1;
    default:
        if (c < 0x80 && !isalnum_ascii(c)) { *out = c; return 1; }
        break;
    }
bad:
    P->err = DMRE_ESYNTAX;
    return 0;
}

/* Go parser.parseClassChar. */
static int class_char(parser *P, uint32_t *out) {
    if (P->i >= P->n) { P->err = DMRE_ESYNTAX; return 0; } /* missing closing ] */
    if (P->s[P->i] == '\\') return parse_escape(P, out);
    return next_rune(P, out);
}

/* Go parser.parseClass at s[i] == '['. Returns the class node or -1. */
static int parse_class(parser *P) {
    P->i++;
    int neg = 0;
    if (P->i < P->n && P->s[P->i] == '^') { neg = 1; P->i++; }
    int start = P->nr;
    int first = 1;
    while (P->i >= P->n || P->s[P->i] != ']' || first) {
        first = 0;
        size_t rem = P->n - P->i;
        /* POSIX [:alnum:] — Go: len(t) > 2, and ":]" searched in the rest of the WHOLE expression. */
        if (rem > 2 && P->s[P->i] == '[' && P->s[P->i + 1] == ':') {
            size_t j = P->i + 2;
            while (j + 1 < P->n && !(P->s[j] == ':' && P->s[j + 1] == ']')) j++;
            if (j + 1 < P->n) {
                const unsigned char *nm = P->s + P->i + 2;
                size_t nlen = j - (P->i + 2);
                int gneg = 0;
                if (nlen > 0 && nm[0] == '^') { gneg = 1; nm++; nlen--; }
                int found = -1;
                for (size_t k = 0; k < sizeof POSIX / sizeof POSIX[0]; k++)
                    if (strlen(POSIX[k].name) == nlen && memcmp(POSIX[k].name, nm, nlen) == 0) { found = (int)k; break; }
                if (found < 0) { P->err = DMRE_ESYNTAX; return -1; }
                if (!add_group(P, POSIX[found].g, POSIX[found].npairs, gneg)) return -1;
                P->i = j + 2;
                continue;
            }
        }
        /* \p{...} / \pX: Unicode groups are not supported here (see the file header). */
        if (rem >= 2 && P->s[P->i] == '\\' && (P->s[P->i + 1] == 'p' || P->s[P->i + 1] == 'P')) {
            P->err = DMRE_ESYNTAX; return -1;
        }
        if (perl_class(P)) { if (P->err) return -1; continue; }
        uint32_t lo, hi;
        if (!class_char(P, &lo)) return -1;
        hi = lo;
        if (P->n - P->i >= 2 && P->s[P->i] == '-' && P->s[P->i + 1] != ']') {
            P->i++;
            if (!class_char(P, &hi)) return -1;
            if (hi < lo) { P->err = DMRE_ESYNTAX; return -1; } /* invalid character class range */
        }
        if (!add_range(P, lo, hi)) return -1;
    }
    P->i++; /* chop ] */
    if (!grow((void **)&P->classes, &P->ccap, P->nc + 1, sizeof(cclass))) { P->err = DMRE_ENOMEM; return -1; }
    P->classes[P->nc].start = start;
    P->classes[P->nc].count = (P->nr - start) / 2;
    P->classes[P->nc].neg = neg;
    return new_node(P, N_CLASS, (uint32_t)P->nc++);
}

static int parse_alt(parser *P);

/* Go parser.parseInt: digits, no leading zero; a value >= 1e8 is -1. Returns 0 when not a number. */
static int parse_int(parser *P, size_t *j, int *out) {
    size_t k = *j;
    if (k >= P->n || P->s[k] < '0' || P->s[k] > '9') return 0;
    if (k + 1 < P->n && P->s[k] == '0' && P->s[k + 1] >= '0' && P->s[k + 1] <= '9') return 0;
    int v = 0;
    for (; k < P->n && P->s[k] >= '0' && P->s[k] <= '9'; k++) {
        if (v >= 100000000) { v = -1; while (k < P->n && P->s[k] >= '0' && P->s[k] <= '9') k++; break; }
        v = v * 10 + (P->s[k] - '0');
    }
    *j = k; *out = v;
    return 1;
}

/* Go parser.parseRepeat at '{': {n} {n,} {n,m}. 1 with the bounds (max -1 = unbounded; min -1 = too big)
 * and *end just past '}', or 0 when it is not that shape (then '{' is a literal). */
static int parse_repeat(parser *P, int *min, int *max, size_t *end) {
    size_t j = P->i + 1;
    if (!parse_int(P, &j, min)) return 0;
    if (j >= P->n) return 0;
    if (P->s[j] != ',') *max = *min;
    else {
        j++;
        if (j >= P->n) return 0;
        if (P->s[j] == '}') *max = -1;
        else if (!parse_int(P, &j, max)) return 0;
        else if (*max < 0) *min = -1;
    }
    if (j >= P->n || P->s[j] != '}') return 0;
    *end = j + 1;
    return 1;
}

/* Go repeatIsValid: the product of nested counted repetitions stays within n copies. */
static int repeat_is_valid(const parser *P, int k, int n) {
    const node *nd = &P->nodes[k];
    if (nd->op == N_REPEAT) {
        int m = nd->max;
        if (m == 0) return 1;
        if (m < 0) m = nd->min;
        if (m > n) return 0;
        if (m > 0) n /= m;
    }
    for (int c = nd->kid; c >= 0; c = P->nodes[c].next)
        if (!repeat_is_valid(P, c, n)) return 0;
    return 1;
}

/* Wrap the concatenation's last item in a repetition (Go parser.repeat). */
static int apply_repeat(parser *P, int cat, int op, int min, int max, int last_repeat) {
    if (P->i < P->n && P->s[P->i] == '?') P->i++;          /* non-greedy: the same language */
    if (last_repeat) { P->err = DMRE_ESYNTAX; return 0; }   /* invalid nested repetition operator */
    node *cn = &P->nodes[cat];
    if (cn->last < 0) { P->err = DMRE_ESYNTAX; return 0; }  /* missing argument to repetition operator */
    int sub = cn->last;
    int q = new_node(P, op, 0);
    if (q < 0) return 0;
    cn = &P->nodes[cat];
    P->nodes[q].kid = P->nodes[q].last = sub;
    P->nodes[q].min = min; P->nodes[q].max = max;
    if (cn->kid == sub) cn->kid = q;
    else { int k = cn->kid; while (P->nodes[k].next != sub) k = P->nodes[k].next; P->nodes[k].next = q; }
    cn->last = q;
    P->nodes[sub].next = -1;
    if (op == N_REPEAT && (min >= 2 || max >= 2) && !repeat_is_valid(P, q, 1000)) { P->err = DMRE_ESYNTAX; return 0; }
    return finish_node(P, q);
}

/* A concatenation: items until '|', ')' or the end. Go's lastRepeat rule: a quantifier directly after
 * a quantifier (incl. its non-greedy '?') is an error; a quantifier with nothing before it too. */
static int parse_concat(parser *P) {
    int cat = new_node(P, N_CAT, 0);
    if (cat < 0) return -1;
    int last_repeat = 0;
    while (P->i < P->n && P->s[P->i] != '|' && P->s[P->i] != ')') {
        int repeat = 0, item = -1;
        unsigned char c = P->s[P->i];
        switch (c) {
        case '(': {
            if (P->i + 1 < P->n && P->s[P->i + 1] == '?') { P->err = DMRE_ESYNTAX; return -1; } /* (?flags): unsupported */
            if (++P->depth > 1000) { P->err = DMRE_ESYNTAX; return -1; }
            P->i++;
            int g = parse_alt(P);
            if (g < 0) return -1;
            if (P->i >= P->n || P->s[P->i] != ')') { P->err = DMRE_ESYNTAX; return -1; } /* missing ) */
            P->i++;
            P->depth--;
            item = new_node(P, N_CAPTURE, 0);
            if (item >= 0) { P->nodes[item].kid = P->nodes[item].last = g; if (!finish_node(P, item)) return -1; }
            break;
        }
        case '^': P->i++; item = new_node(P, N_BOT, 0); break;
        case '$': P->i++; item = new_node(P, N_EOT, 0); break;
        case '.': P->i++; item = new_node(P, N_ANY, 0); break;
        case '[': item = parse_class(P); break;
        case '*': case '+': case '?':
            P->i++;
            if (!apply_repeat(P, cat, c == '*' ? N_STAR : c == '+' ? N_PLUS : N_QUEST, 0, 0, last_repeat)) return -1;
            repeat = 1;
            item = -2;
            break;
        case '{': {
            int min = 0, max = 0;
            size_t end;
            if (!parse_repeat(P, &min, &max, &end)) { P->i++; item = new_node(P, N_LIT, '{'); break; }
            if (min < 0 || min > 1000 || max > 1000 || (max >= 0 && min > max)) { P->err = DMRE_ESYNTAX; return -1; }
            P->i = end;
            if (!apply_repeat(P, cat, N_REPEAT, min, max, last_repeat)) return -1;
            repeat = 1;
            item = -2;
            break;
        }
        case '\\': {
            if (P->i + 1 < P->n) {
                unsigned char e = P->s[P->i + 1];
                if (e == 'A') { P->i += 2; item = new_node(P, N_BOT, 0); break; }
                if (e == 'z') { P->i += 2; item = new_node(P, N_EOT, 0); break; }
                if (e == 'b') { P->i += 2; item = new_node(P, N_WB, 0); break; }
                if (e == 'B') { P->i += 2; item = new_node(P, N_NWB, 0); break; }
                if (e == 'C') { P->err = DMRE_ESYNTAX; return -1; }
                if (e == 'Q') {
                    size_t j = P->i + 2, end = P->n, resume = P->n;
                    for (size_t k = j; k + 1 < P->n; k++)
                        if (P->s[k] == '\\' && P->s[k + 1] == 'E') { end = k; resume = k + 2; break; }
                    P->i = j;
                    while (P->i < end) {
                        size_t w;
                        uint32_t r = dm__utf8_decode(P->s + P->i, end - P->i, &w);
                        if (r == 0xFFFD && w == 1) { P->err = DMRE_ESYNTAX; return -1; }
                        P->i += w;
                        int l = new_node(P, N_LIT, r);
                        if (l < 0) return -1;
                        add_kid(P, cat, l);
                    }
                    P->i = resume;
                    item = -2; /* nothing more to add */
                    break;
                }
                if (e == 'p' || e == 'P') { P->err = DMRE_ESYNTAX; return -1; } /* unsupported */
            }
            size_t at = P->i;
            int cs = P->nr;
            if (perl_class(P)) {
                if (P->err) return -1;
                if (!grow((void **)&P->classes, &P->ccap, P->nc + 1, sizeof(cclass))) { P->err = DMRE_ENOMEM; return -1; }
                P->classes[P->nc].start = cs;
                P->classes[P->nc].count = (P->nr - cs) / 2;
                P->classes[P->nc].neg = 0;
                item = new_node(P, N_CLASS, (uint32_t)P->nc++);
                break;
            }
            P->i = at;
            uint32_t r;
            if (!parse_escape(P, &r)) return -1;
            item = new_node(P, N_LIT, r);
            break;
        }
        default: {
            uint32_t r;
            if (!next_rune(P, &r)) return -1;
            item = new_node(P, N_LIT, r);
            break;
        }
        }
        if (P->err) return -1;
        if (item >= 0) add_kid(P, cat, item);
        last_repeat = repeat;
    }
    node *cn = &P->nodes[cat];
    if (cn->kid < 0) cn->op = N_EMPTY;
    else if (cn->kid == cn->last) return cn->kid;  /* Go: a one-item concatenation is the item */
    if (!finish_node(P, cat)) return -1;
    return cat;
}

static int parse_alt(parser *P) {
    int first = parse_concat(P);
    if (first < 0) return -1;
    if (P->i >= P->n || P->s[P->i] != '|') return first;
    int alt = new_node(P, N_ALT, 0);
    if (alt < 0) return -1;
    add_kid(P, alt, first);
    while (P->i < P->n && P->s[P->i] == '|') {
        P->i++;
        int c = parse_concat(P);
        if (c < 0) return -1;
        add_kid(P, alt, c);
    }
    if (!finish_node(P, alt)) return -1;
    return alt;
}

/* ---------------------------------------------------------------- compile to a program */

typedef struct { inst *prog; int n, cap; int err; } emitter;

static int emit(emitter *E, int op, uint32_t arg, int x, int y) {
    if (!grow((void **)&E->prog, &E->cap, E->n + 1, sizeof(inst))) { E->err = DMRE_ENOMEM; return -1; }
    E->prog[E->n].op = op; E->prog[E->n].arg = arg; E->prog[E->n].x = x; E->prog[E->n].y = y;
    return E->n++;
}

enum { A_BOT, A_EOT, A_WB, A_NWB };

static void gen(emitter *E, const node *nodes, int k) {
    if (E->err) return;
    const node *nd = &nodes[k];
    switch (nd->op) {
    case N_LIT: emit(E, I_RUNE, nd->v, 0, 0); break;
    case N_CLASS: emit(E, I_CLASS, nd->v, 0, 0); break;
    case N_ANY: emit(E, I_ANY, 0, 0, 0); break;
    case N_BOT: emit(E, I_ASSERT, A_BOT, 0, 0); break;
    case N_EOT: emit(E, I_ASSERT, A_EOT, 0, 0); break;
    case N_WB: emit(E, I_ASSERT, A_WB, 0, 0); break;
    case N_NWB: emit(E, I_ASSERT, A_NWB, 0, 0); break;
    case N_EMPTY: break;
    case N_CAT:
        for (int c = nd->kid; c >= 0 && !E->err; c = nodes[c].next) gen(E, nodes, c);
        break;
    case N_ALT: {
        /* SPLIT next, alt2 ; c1 ; JMP end ; alt2: SPLIT ... ; ck ; end: — the JMPs chained then patched */
        int jmps = -1; /* linked through .x of the JMP instructions */
        for (int c = nd->kid; c >= 0 && !E->err; c = nodes[c].next) {
            if (nodes[c].next >= 0) {
                int sp = emit(E, I_SPLIT, 0, 0, 0);
                if (sp < 0) return;
                E->prog[sp].x = sp + 1;
                gen(E, nodes, c);
                int j = emit(E, I_JMP, 0, jmps, 0);
                if (j < 0) return;
                jmps = j;
                E->prog[sp].y = E->n;
            } else gen(E, nodes, c);
        }
        if (E->err) return;
        while (jmps >= 0) { int nx = E->prog[jmps].x; E->prog[jmps].x = E->n; jmps = nx; }
        break;
    }
    case N_STAR: {
        int sp = emit(E, I_SPLIT, 0, 0, 0);
        if (sp < 0) return;
        E->prog[sp].x = sp + 1;
        gen(E, nodes, nd->kid);
        if (emit(E, I_JMP, 0, sp, 0) < 0) return;
        E->prog[sp].y = E->n;
        break;
    }
    case N_PLUS: {
        int top = E->n;
        gen(E, nodes, nd->kid);
        if (E->err) return;
        int sp = emit(E, I_SPLIT, 0, top, 0);
        if (sp < 0) return;
        E->prog[sp].y = sp + 1;
        break;
    }
    case N_CAPTURE: gen(E, nodes, nd->kid); break;
    case N_REPEAT: {
        /* x{n,m} = n copies, then (x(x(x)?)?)? for the m-n optional ones; x{n,} = n copies + x* */
        for (int k = 0; k < nd->min && !E->err; k++) gen(E, nodes, nd->kid);
        if (E->err) return;
        if (nd->max == -1) {
            int sp = emit(E, I_SPLIT, 0, 0, 0);
            if (sp < 0) return;
            E->prog[sp].x = sp + 1;
            gen(E, nodes, nd->kid);
            if (emit(E, I_JMP, 0, sp, 0) < 0) return;
            E->prog[sp].y = E->n;
        } else if (nd->max > nd->min) {
            int first = E->n, nsplit = nd->max - nd->min;
            for (int k = 0; k < nsplit && !E->err; k++) {
                int sp = emit(E, I_SPLIT, 0, 0, -1);
                if (sp < 0) return;
                E->prog[sp].x = sp + 1;
                gen(E, nodes, nd->kid);
            }
            if (E->err) return;
            for (int pc = first; pc < E->n; pc++)   /* patch the optional copies' exits */
                if (E->prog[pc].op == I_SPLIT && E->prog[pc].y == -1) E->prog[pc].y = E->n;
        }
        break;
    }
    case N_QUEST: {
        int sp = emit(E, I_SPLIT, 0, 0, 0);
        if (sp < 0) return;
        E->prog[sp].x = sp + 1;
        gen(E, nodes, nd->kid);
        E->prog[sp].y = E->n;
        break;
    }
    }
}

void dmre_free(dmre *r) {
    if (!r) return;
    free(r->prog); free(r->ranges); free(r->classes); free(r->pre); free(r->suf); free(r);
}

int dmre_compile(const char *re, size_t len, dmre **out) {
    *out = NULL;
    parser P;
    memset(&P, 0, sizeof P);
    P.s = (const unsigned char *)re; P.n = len;
    int root = parse_alt(&P);
    if (root >= 0 && !P.err && P.i < P.n) P.err = DMRE_ESYNTAX; /* unexpected ) */
    int rc = P.err ? P.err : (root < 0 ? DMRE_ESYNTAX : DMRE_OK);
    emitter E = { NULL, 0, 0, 0 };
    if (rc == DMRE_OK) {
        gen(&E, P.nodes, root);
        if (!E.err) emit(&E, I_MATCH, 0, 0, 0);
        if (E.err) rc = E.err;
    }
    dmre *r = rc == DMRE_OK ? calloc(1, sizeof *r) : NULL;
    if (rc == DMRE_OK && !r) rc = DMRE_ENOMEM;
    if (rc == DMRE_OK && P.nodes[root].op == N_CAT) {
        int kids[2048], nk = 0, more = 0;
        for (int c = P.nodes[root].kid; c >= 0; c = P.nodes[c].next) {
            if (nk == 2048) { more = 1; break; }
            kids[nk++] = c;
        }
        int a = 0;
        size_t cap = len * 4 + 4;
        if (nk > 0 && P.nodes[kids[0]].op == N_BOT && (r->pre = malloc(cap)) != NULL) {
            for (a = 1; a < nk && P.nodes[kids[a]].op == N_LIT && P.nodes[kids[a]].v != 0xFFFD; a++)
                r->npre += dm__utf8_encode(P.nodes[kids[a]].v, r->pre + r->npre);
        }
        if (!more && nk > 0 && P.nodes[kids[nk - 1]].op == N_EOT && (r->suf = malloc(cap)) != NULL) {
            int k = nk - 2;
            while (k >= a && P.nodes[kids[k]].op == N_LIT && P.nodes[kids[k]].v != 0xFFFD) k--;
            for (int j = k + 1; j <= nk - 2; j++) r->nsuf += dm__utf8_encode(P.nodes[kids[j]].v, r->suf + r->nsuf);
        }
    }
    free(P.nodes);
    if (rc != DMRE_OK) { free(P.ranges); free(P.classes); free(E.prog); dmre_free(r); return rc; }
    r->prog = E.prog; r->ninst = E.n;
    r->ranges = P.ranges; r->classes = P.classes;
    r->anchored = E.prog[0].op == I_ASSERT && E.prog[0].arg == A_BOT;
    *out = r;
    return DMRE_OK;
}

/* ---------------------------------------------------------------- Pike VM */

static int isword(unsigned char b) {
    return (b >= '0' && b <= '9') || (b >= 'A' && b <= 'Z') || (b >= 'a' && b <= 'z') || b == '_';
}

typedef struct {
    const dmre *re;
    int *mark, *stk;
    int gen;
} vm;

/* Add the epsilon closure of pc, at a position whose context is (bot, eot, wb), to list. */
static void addthread(vm *V, int *list, int *nlist, int pc, int bot, int eot, int wb) {
    int sp = 0;
    const inst *prog = V->re->prog;
    if (V->mark[pc] == V->gen) return;
    V->mark[pc] = V->gen;
    V->stk[sp++] = pc;
    while (sp > 0) {
        int p = V->stk[--sp];
        const inst *in = &prog[p];
        int t1 = -1, t2 = -1;
        switch (in->op) {
        case I_JMP: t1 = in->x; break;
        case I_SPLIT: t1 = in->x; t2 = in->y; break;
        case I_ASSERT: {
            int ok = in->arg == A_BOT ? bot : in->arg == A_EOT ? eot : in->arg == A_WB ? wb : !wb;
            if (ok) t1 = p + 1;
            break;
        }
        default: list[(*nlist)++] = p; break;
        }
        if (t2 >= 0 && V->mark[t2] != V->gen) { V->mark[t2] = V->gen; V->stk[sp++] = t2; }
        if (t1 >= 0 && V->mark[t1] != V->gen) { V->mark[t1] = V->gen; V->stk[sp++] = t1; }
    }
}

static int class_has(const dmre *re, uint32_t ci, uint32_t r) {
    const cclass *c = &re->classes[ci];
    const uint32_t *g = re->ranges + c->start;
    int in = 0;
    for (int k = 0; k < c->count; k++) if (r >= g[2 * k] && r <= g[2 * k + 1]) { in = 1; break; }
    return in != c->neg;
}

#define DMRE_STACK_INTS 1024

int dmre_match(const dmre *re, const char *str, size_t n) {
    const unsigned char *s = (const unsigned char *)str;
    if (re->npre && (n < re->npre || memcmp(s, re->pre, re->npre) != 0)) return 0;
    if (re->nsuf && (n < re->nsuf || memcmp(s + n - re->nsuf, re->suf, re->nsuf) != 0)) return 0;
    int N = re->ninst;
    int stackbuf[DMRE_STACK_INTS];
    int *mem = stackbuf;
    if ((size_t)N * 4 > DMRE_STACK_INTS) {
        mem = malloc((size_t)N * 4 * sizeof(int));
        if (!mem) return DMRE_ENOMEM;
    }
    int *cl = mem, *nl = mem + N;
    vm V = { re, mem + 2 * N, mem + 3 * N, 0 };
    memset(V.mark, 0, (size_t)N * sizeof(int));
    int ncl = 0, nnl = 0, result = 0;
    size_t pos = 0;
    V.gen = 1;
    for (;;) {
        int bot = pos == 0, eot = pos == n;
        int wb = (pos > 0 && isword(s[pos - 1])) != (pos < n && isword(s[pos]));
        if (pos == 0 || !re->anchored) addthread(&V, cl, &ncl, 0, bot, eot, wb);
        if (ncl == 0 && re->anchored) break;
        uint32_t r = 0;
        size_t w = 0;
        if (pos < n) r = dm__utf8_decode(s + pos, n - pos, &w);
        size_t np = pos + w;
        int nbot = 0, neot = np == n;
        int nwb = (np > 0 && isword(s[np - 1])) != (np < n && isword(s[np]));
        V.gen++;
        nnl = 0;
        for (int k = 0; k < ncl; k++) {
            const inst *in = &re->prog[cl[k]];
            int ok = 0;
            switch (in->op) {
            case I_MATCH: result = 1; goto done;
            case I_RUNE: ok = pos < n && r == in->arg; break;
            case I_CLASS: ok = pos < n && class_has(re, in->arg, r); break;
            case I_ANY: ok = pos < n && r != '\n'; break;
            default: break;
            }
            if (ok) addthread(&V, nl, &nnl, cl[k] + 1, nbot, neot, nwb);
        }
        if (pos >= n) break;
        int *t = cl; cl = nl; nl = t;
        ncl = nnl;
        pos = np;
    }
done:
    if (mem != stackbuf) free(mem);
    return result;
}
