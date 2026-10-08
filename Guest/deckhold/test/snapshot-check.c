/*
 * snapshot-check.c — 610 (issue 609.B1): deckhold's SNAPSHOT must reproduce its own screen EXACTLY on a
 * viewer, after any resize (a narrowing reflow included). Before 610, right after a session's size switched
 * back (another viewer had resized it), the snapshot lost an empty row that continued a soft-wrapped line:
 * the formatter's `unwrap` joins a wrapped row with its continuation but counts the newline only for the
 * continuation — and a continuation with no text is "blank", so its newline was folded into the next
 * non-blank row's. One row short; a TUI's prompt sat a row off in the web pane until it redrew.
 *
 * This is deckhold's own code (`#include "../deckhold.c"`), built for the Mac against a Mac libghostty-vt
 * from the SAME pinned ghostty commit (Guest/deckhold/test/run.sh): each case feeds bytes to the holder's
 * emulator, resizes it as a viewer's HELLO/RESIZE would (resize_to — the reflow), builds the snapshot
 * (send_snapshot) and replays it into a FRESH emulator of the same size — then compares every cell of the
 * active area (codepoint), each row's soft-wrap flag, and the cursor. Fixed cases (the 609 shape) first, then
 * a seeded fuzz of screens and size sequences.
 *
 * Exit 0 = every case matched. Usage: snapshot-check [fuzz-iterations] [seed]
 */
#define main deckhold_main
#include "../deckhold.c"
#undef main

static int failures, cases;

static GhosttyTerminal fresh(uint16_t cols, uint16_t rows) {
    GhosttyTerminal t = NULL;
    GhosttyTerminalOptions to = { .cols = cols, .rows = rows, .max_scrollback = 10u << 20 };
    if (ghostty_terminal_new(NULL, &t, to) != GHOSTTY_SUCCESS) { fprintf(stderr, "ghostty_terminal_new failed\n"); exit(2); }
    return t;
}

/* The holder as `serve` sets it up — the pty is absent (resize_to's TIOCSWINSZ on -1 is a no-op). */
static void holder(uint16_t cols, uint16_t rows) {
    if (S.term) ghostty_terminal_free(S.term);
    S.term = fresh(cols, rows);
    S.cols = cols; S.rows = rows;
    S.master = -1;
    S.screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY;
}

static void feed(const char *s) { ghostty_terminal_vt_write(S.term, (const uint8_t *)s, strlen(s)); }

/* One cell as a character for the report (wide/other code points as '#'). A cell with no text and a space
 * look the same and are the same to the viewer (the formatter writes the blanks before text as spaces). */
static char cell_char(GhosttyTerminal t, uint16_t x, uint16_t y, bool *ok) {
    GhosttyPoint p = { .tag = GHOSTTY_POINT_TAG_ACTIVE, .value.coordinate = { .x = x, .y = y } };
    GhosttyGridRef r = { .size = sizeof r };
    GhosttyCell c = 0;
    if (ghostty_terminal_grid_ref(t, p, &r) != GHOSTTY_SUCCESS || ghostty_grid_ref_cell(&r, &c) != GHOSTTY_SUCCESS) { *ok = false; return '?'; }
    uint32_t cp = 0;
    ghostty_cell_get(c, GHOSTTY_CELL_DATA_CODEPOINT, &cp);
    if (cp == 0) return ' ';
    return cp < 128 ? (char)cp : '#';
}

static int wide_of(GhosttyTerminal t, uint16_t x, uint16_t y) {
    GhosttyPoint p = { .tag = GHOSTTY_POINT_TAG_ACTIVE, .value.coordinate = { .x = x, .y = y } };
    GhosttyGridRef r = { .size = sizeof r };
    GhosttyCell c = 0;
    GhosttyCellWide w = GHOSTTY_CELL_WIDE_NARROW;
    if (ghostty_terminal_grid_ref(t, p, &r) == GHOSTTY_SUCCESS && ghostty_grid_ref_cell(&r, &c) == GHOSTTY_SUCCESS)
        ghostty_cell_get(c, GHOSTTY_CELL_DATA_WIDE, &w);
    return (int)w;
}

static bool row_wrap(GhosttyTerminal t, uint16_t y) {
    GhosttyPoint p = { .tag = GHOSTTY_POINT_TAG_ACTIVE, .value.coordinate = { .x = 0, .y = y } };
    GhosttyGridRef r = { .size = sizeof r };
    GhosttyRow row = 0;
    bool w = false;
    if (ghostty_terminal_grid_ref(t, p, &r) == GHOSTTY_SUCCESS && ghostty_grid_ref_row(&r, &row) == GHOSTTY_SUCCESS)
        ghostty_row_get(row, GHOSTTY_ROW_DATA_WRAP, &w);
    return w;
}

/* The screen as text: one line per row ("|" + cells + "|" + wrap marker), then the cursor. The wrap marker
 * ('w') is compared where it is MEANINGFUL — a row with text soft-wrapped into a row with text (a selection
 * or a copy joins them). A wrap into or out of an empty row joins nothing; the snapshot places the rows
 * around it by position, and the viewer learns such a wrap only when something is printed there. */
static char *screen_text(GhosttyTerminal t, uint16_t cols, uint16_t rows) {
    size_t n = (size_t)(cols + 4) * rows + 64;
    char *s = calloc(1, n), *p = s;
    bool ok = true;
    char *line_start[1001];
    for (uint16_t y = 0; y < rows; y++) {
        line_start[y] = p;
        *p++ = '|';
        for (uint16_t x = 0; x < cols; x++) *p++ = cell_char(t, x, y, &ok);
        *p++ = '|';
        *p++ = row_wrap(t, y) ? 'w' : ' ';
        *p++ = '\n';
    }
    for (uint16_t y = 0; y < rows; y++) {
        char *w = line_start[y] + cols + 2;
        if (*w != 'w') continue;
        bool next_text = false, this_text = false;
        if (y + 1 < rows) for (uint16_t x = 0; x < cols; x++) if (line_start[y + 1][1 + x] != ' ') { next_text = true; break; }
        for (uint16_t x = 0; x < cols; x++) if (line_start[y][1 + x] != ' ') { this_text = true; break; }
        /* An orphaned spacer head (its wide character erased since it wrapped) leaves a stale wrap: the
         * snapshot places the next row by position, so the viewer has no wrap there — nothing joins. */
        bool orphan = y + 1 < rows && wide_of(t, (uint16_t)(cols - 1), y) == GHOSTTY_CELL_WIDE_SPACER_HEAD &&
                      wide_of(t, 0, (uint16_t)(y + 1)) != GHOSTTY_CELL_WIDE_WIDE;
        if (!next_text || !this_text || orphan) *w = ' ';
    }
    uint16_t cx = 0, cy = 0;
    ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_CURSOR_X, &cx);
    ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &cy);
    snprintf(p, 64, "cursor %u,%u%s\n", cx, cy, ok ? "" : " (unreadable cells)");
    return s;
}

/* Build the snapshot the holder would send a viewer now, replay it on a fresh viewer, compare. */
static bool snapshot_matches(const char *label, bool verbose) {
    struct client c;
    memset(&c, 0, sizeof c);
    c.fd = -1;
    send_snapshot(&c, "check");
    cases++;
    if (c.out.len < 5 || c.out.p[0] != F_SNAPSHOT) { printf("FAIL %s: no SNAPSHOT frame\n", label); failures++; return false; }
    uint32_t n = be32(c.out.p + 1);
    const char *dump = getenv("SNAPSHOT_DUMP");             /* SNAPSHOT_DUMP="fuzz 46 step 1": its bytes → stdout */
    if (dump && !strcmp(dump, label)) {
        printf("--- snapshot of %s (%u bytes):\n", label, n);
        for (uint32_t i = 0; i < n; i++) {
            uint8_t ch = c.out.p[5 + i];
            if (ch == 0x1b) printf("^[");
            else if (ch == '\r') printf("^M");
            else if (ch == '\n') printf("^J\n");
            else if (ch < 32) printf("^%c", ch + 64);
            else putchar(ch);
        }
        printf("\n---\n");
    }
    GhosttyTerminal v = fresh(S.cols, S.rows);
    ghostty_terminal_vt_write(v, c.out.p + 5, n);
    char *want = screen_text(S.term, S.cols, S.rows), *got = screen_text(v, S.cols, S.rows);
    bool same = strcmp(want, got) == 0;
    if (!same) {
        failures++;
        printf("FAIL %s (%ux%u): the viewer's screen differs from the holder's\n", label, S.cols, S.rows);
        if (verbose) {
            /* Row by row, only the rows that differ (and the cursor line). */
            char *a = want, *b = got;
            for (int y = 0; *a && *b; y++) {
                char *ea = strchr(a, '\n'), *eb = strchr(b, '\n');
                if (!ea || !eb) break;
                if ((ea - a) != (eb - b) || memcmp(a, b, (size_t)(ea - a)))
                    printf("  row %2d holder %.*s\n         viewer %.*s\n", y, (int)(ea - a), a, (int)(eb - b), b);
                a = ea + 1; b = eb + 1;
            }
        }
    } else if (verbose) {
        printf("PASS %s (%ux%u)\n", label, S.cols, S.rows);
    }
    free(want); free(got);
    ghostty_terminal_free(v);
    buf_free(&c.out);
    return same;
}

/* ── fixed cases ─────────────────────────────────────────────────────────────────────────── */

/* 609's shape: a prompt drawn at 100 columns with rows padded by spaces to the edge (a TUI clearing with
 * spaces), two blank rows above the prompt, a rule below; the session switches to 78×47 and back. */
static void case_tui_switch(void) {
    holder(78, 47);
    feed("\x1b[2J\x1b[H");
    feed("welcome to the program\r\n");
    holder(100, 30);
    feed("\x1b[2J\x1b[H");
    char line[256];
    for (int i = 0; i < 6; i++) {
        snprintf(line, sizeof line, "line %d of the conversation", i);
        feed(line);
        for (int k = (int)strlen(line); k < 100; k++) feed(" ");      /* padded to the edge: wrap pending */
    }
    feed("\r\n\r\n");
    feed("\x1b[38;5;244m");
    for (int i = 0; i < 100; i++) feed("\xe2\x94\x80");               /* a rule, full width */
    feed("\x1b[0m\r\n\xe2\x9d\xaf alpha one two\r\n");
    for (int i = 0; i < 100; i++) feed("\xe2\x94\x80");
    feed("\x1b[15;10H");
    snapshot_matches("609 shape at 100x30", true);
    resize_to(78, 47);
    snapshot_matches("609 shape narrowed to 78x47 (the switch back)", true);
    resize_to(100, 30);
    snapshot_matches("609 shape widened to 100x30", true);
    resize_to(78, 47);
    snapshot_matches("609 shape narrowed again", true);
}

/* The minimal case: one soft-wrapped row whose continuation has NO text (only the wrap). */
static void case_blank_continuation(void) {
    holder(20, 6);
    feed("01234567890123456789");          /* exactly the width: the row soft-wraps on the next print */
    feed(" ");                              /* a space on the continuation row … */
    feed("\x1b[1K");                        /* … erased: the continuation has no text */
    feed("\r\nnext line");
    snapshot_matches("a wrapped row with an empty continuation", true);
    holder(20, 6);
    feed("01234567890123456789");
    feed("x\b \b\r\n\r\nafter a blank row");   /* continuation erased by backspace-space, then a blank row */
    snapshot_matches("an emptied continuation followed by a blank row", true);
}

/* A line whose text is an exact multiple of the NEW width after a narrowing reflow: 156 cells at 100 columns
 * (a row and 56 on the next), narrowed to 78 — two full rows, and the old row's empty remainder becomes a third,
 * empty, soft-wrapped row (the shape 609 saw behind Claude Code). */
static void case_exact_multiple(void) {
    holder(100, 30);
    for (int i = 0; i < 156; i++) feed("=");
    feed("\r\n\r\n\xe2\x9d\xaf prompt\r\n");
    for (int i = 0; i < 100; i++) feed("-");
    feed("\x1b[4;10H");
    snapshot_matches("156 cells at 100 columns", true);
    resize_to(78, 47);
    snapshot_matches("… narrowed to 78 (an exact multiple: an empty wrapped row)", true);
    resize_to(100, 30);
    snapshot_matches("… back to 100", true);
}

/* ── the fuzz ─────────────────────────────────────────────────────────────────────────────── */

static uint64_t rng;
static uint32_t rnd(uint32_t n) { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return (uint32_t)(rng % n); }

static void random_screen(uint16_t cols) {
    char b[512];
    int ops = 20 + (int)rnd(60);
    for (int i = 0; i < ops; i++) {
        switch (rnd(10)) {
        case 0: case 1: {                                       /* text, maybe to the edge or past it */
            int len = (int)rnd(cols * 2u);
            for (int k = 0; k < len && k < (int)sizeof b - 1; k++) b[k] = rnd(6) == 0 ? ' ' : (char)('a' + rnd(26));
            b[len < (int)sizeof b - 1 ? len : (int)sizeof b - 1] = 0;
            feed(b);
            break;
        }
        case 2: {                                               /* padded to exactly the edge with spaces */
            uint16_t cx = 0;
            ghostty_terminal_get(S.term, GHOSTTY_TERMINAL_DATA_CURSOR_X, &cx);
            for (int k = cx; k < cols; k++) feed(" ");
            break;
        }
        case 3: feed("\r\n"); break;
        case 4: feed(rnd(2) ? "\x1b[K" : "\x1b[1K"); break;    /* erase to / from the cursor */
        case 5: snprintf(b, sizeof b, "\x1b[%u;%uH", 1 + rnd(S.rows), 1 + rnd(cols)); feed(b); break;
        case 6: feed(rnd(2) ? "\x1b[2K" : "\b \b"); break;
        case 7: feed(rnd(3) ? "\r\n\r\n" : "\x1b[J"); break;
        case 8: snprintf(b, sizeof b, "\x1b[3%um%c\x1b[0m", rnd(8), 'A' + (int)rnd(26)); feed(b); break;
        case 9: feed("\xe2\x94\x80\xe2\x94\x80\xe4\xb8\xad"); break;   /* box drawing + a wide character */
        }
    }
}

static void fuzz(int iterations) {
    static const uint16_t sizes[][2] = { {100, 30}, {78, 47}, {80, 24}, {120, 36}, {40, 12}, {132, 50}, {60, 20} };
    const int nsizes = (int)(sizeof sizes / sizeof sizes[0]);
    int fails0 = failures;
    for (int it = 0; it < iterations; it++) {
        const uint16_t *a = sizes[rnd((uint32_t)nsizes)];
        holder(a[0], a[1]);
        random_screen(a[0]);
        char label[96];
        int steps = 1 + (int)rnd(4);
        for (int s = 0; s < steps; s++) {
            const uint16_t *b = sizes[rnd((uint32_t)nsizes)];
            resize_to(b[0], b[1]);
            if (rnd(2)) random_screen(b[0]);
            snprintf(label, sizeof label, "fuzz %d step %d", it, s);
            if (!snapshot_matches(label, failures - fails0 < 3)) break;
        }
    }
    printf("fuzz: %d iterations, %d failing\n", iterations, failures - fails0);
}

int main(int argc, char **argv) {
    int iterations = argc > 1 ? atoi(argv[1]) : 2000;
    rng = argc > 2 ? strtoull(argv[2], NULL, 10) : 0x610b1u;
    if (!rng) rng = 1;
    case_blank_continuation();
    case_tui_switch();
    case_exact_multiple();
    fuzz(iterations);
    printf("%s: %d cases, %d failed\n", failures ? "snapshot-check FAILED" : "snapshot-check: ALL PASS", cases, failures);
    return failures ? 1 : 0;
}
