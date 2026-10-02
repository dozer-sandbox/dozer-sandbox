/*
 * dozfold.c — dm_fold / dm_fold_pattern (include/dozmatch.h). Per scalar: full canonical decomposition
 * (Hangul algorithmic), simple case folding, full decomposition again; then canonical ordering (each
 * maximal run of ccc > 0 stably sorted by ccc). Tables: dozfold_tables.h, generated with the Swift
 * copy and the vectors by Scripts/gen-dozfold-tables.py. Invalid UTF-8 bytes are copied unchanged
 * (and order like a starter). In a pattern the scalar (or byte) after a backslash is copied unchanged
 * and is a reordering barrier.
 * MIT (this package).
 */
#include "dozmatch.h"
#include "dozre.h"
#include "dozfold_tables.h"

#include <stdlib.h>
#include <string.h>

#define RAW_BYTE 0x80000000u   /* unit holds an invalid byte, copied through */
#define BARRIER  0x40000000u   /* unit is an escaped scalar: kept, never reordered */
#define VALUE    0x001FFFFFu

static int find(const uint32_t *keys, int n, uint32_t key) {
    int lo = 0, hi = n;
    while (lo < hi) {
        int mid = (lo + hi) / 2;
        if (keys[mid] < key) lo = mid + 1; else hi = mid;
    }
    return lo < n && keys[lo] == key ? lo : -1;
}

static unsigned ccc_of(uint32_t u) {
    if (u & (RAW_BYTE | BARRIER)) return 0;
    int i = find(dmf_ccc_keys, DMF_CCC_N, u);
    return i < 0 ? 0 : dmf_ccc_vals[i];
}

/* Full canonical decomposition of c into out (<= 4 scalars); returns the count. */
static int decompose(uint32_t c, uint32_t *out) {
    if (c >= 0xAC00 && c < 0xAC00 + 11172) {
        uint32_t s = c - 0xAC00;
        out[0] = 0x1100 + s / 588;
        out[1] = 0x1161 + (s % 588) / 28;
        if (s % 28) { out[2] = 0x11A7 + s % 28; return 3; }
        return 2;
    }
    int i = find(dmf_decomp_keys, DMF_DECOMP_N, c);
    if (i < 0) { out[0] = c; return 1; }
    int n = dmf_decomp_lens[i];
    memcpy(out, dmf_decomp_data + dmf_decomp_offs[i], (size_t)n * sizeof(uint32_t));
    return n;
}

static char *run(const char *in, int pattern) {
    const unsigned char *s = (const unsigned char *)in;
    size_t n = strlen(in);
    /* every input byte yields at most DMF_MAX_EXPANSION units (a scalar is >= 1 byte) */
    size_t cap = n * DMF_MAX_EXPANSION + 1;
    uint32_t *u = malloc(cap * sizeof *u);
    if (!u) return NULL;
    size_t m = 0, i = 0;
    while (i < n) {
        size_t w;
        uint32_t c = dm__utf8_decode(s + i, n - i, &w);
        if (c == 0xFFFD && w == 1) u[m++] = RAW_BYTE | s[i];
        else {
            uint32_t d1[8], d2[8];
            int k1 = decompose(c, d1);
            for (int a = 0; a < k1; a++) {
                int fi = find(dmf_fold_keys, DMF_FOLD_N, d1[a]);
                int k2 = decompose(fi < 0 ? d1[a] : dmf_fold_vals[fi], d2);
                for (int b = 0; b < k2; b++) u[m++] = d2[b];
            }
        }
        int esc = pattern && s[i] == '\\';
        i += w;
        if (esc && i < n) {
            c = dm__utf8_decode(s + i, n - i, &w);
            u[m++] = (c == 0xFFFD && w == 1) ? (RAW_BYTE | s[i]) : (BARRIER | c);
            i += w;
        }
    }
    /* canonical ordering: stable insertion sort of each run of ccc > 0 */
    for (size_t a = 0; a < m;) {
        if (ccc_of(u[a]) == 0) { a++; continue; }
        size_t b = a;
        while (b < m && ccc_of(u[b]) > 0) b++;
        for (size_t x = a + 1; x < b; x++) {
            uint32_t v = u[x];
            unsigned kv = ccc_of(v);
            size_t y = x;
            while (y > a && ccc_of(u[y - 1]) > kv) { u[y] = u[y - 1]; y--; }
            u[y] = v;
        }
        a = b;
    }
    char *out = malloc(m * 4 + 1);
    if (!out) { free(u); return NULL; }
    size_t o = 0;
    for (size_t a = 0; a < m; a++) {
        if (u[a] & RAW_BYTE) out[o++] = (char)(u[a] & 0xFF);
        else o += dm__utf8_encode(u[a] & VALUE, (unsigned char *)out + o);
    }
    out[o] = 0;
    free(u);
    return out;
}

char *dm_fold(const char *s) { return run(s, 0); }
char *dm_fold_pattern(const char *p) { return run(p, 1); }
