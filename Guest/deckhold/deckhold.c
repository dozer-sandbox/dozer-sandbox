/*
 * deckhold — a guest-side PTY holder on headless libghostty-vt.
 *
 * Productised in DozerKit (feature 578) from the reference design proven in probe 576
 * (an earlier suspend/resume prototype; the design notes are not part of this repository).
 * Changes since the probe: `deckhold pipe` (the host's frame transport, below), the NAME.exit
 * record a finished session leaves behind, and `ls` listing ended sessions.
 *
 * THE PROBLEM IT SOLVES (576.03): a sandbox that sleeps to disk severs every exec's stdio, so a
 * terminal session must live in a process inside the guest that owns the PTY master and outlives
 * its viewers. tmux does that but brings its own UI (status bar, prefix key, its own redraw);
 * dtach does that but has no screen model, so a reattaching viewer sees nothing until the program
 * redraws. Sprites (fly.io) holds a session with a daemon that owns the PTY master and, on
 * reattach, replays an emulator-RENDERED screen reflowed to the viewer's size. This is that
 * daemon, with Ghostty's terminal core as the emulator.
 *
 * DESIGN (one process per session, one thread, one poll loop):
 *
 *     program ⇄ pty slave │ pty master ⇄ deckhold serve ⇄ /run/deckhold/NAME.sock ⇄ deckhold attach ⇄ viewer
 *                                          │
 *                                          └─ ghostty terminal (headless): every output byte is
 *                                             fed to it, so it always holds the current screen,
 *                                             scrollback, modes, palette, cursor.
 *
 *   - master readable → ghostty_terminal_vt_write(bytes) AND broadcast the same raw bytes to every
 *     attached client. Live output is NOT re-rendered: viewers get the program's own bytes, so
 *     steady-state cost is one memcpy per client plus the emulator's parse.
 *   - a client attaches → HELLO{cols,rows} → the pty (TIOCSWINSZ, which SIGWINCHes the program)
 *     and the emulator (ghostty_terminal_resize, which reflows the primary screen) take the
 *     client's size — the last client to attach or resize wins — and the client is sent ONE
 *     SNAPSHOT: a reset, then the emulator's state formatted back out as VT. Because the snapshot
 *     is built inside the same loop iteration that registers the client, no output byte can fall
 *     between the snapshot and the first live DATA frame, and none can be sent twice.
 *   - the viewer's keystrokes → DATA frames → the master. Resizes → RESIZE frames.
 *   - the program exits → EXIT{code} to every client, the socket is removed, deckhold exits.
 *
 * THE SNAPSHOT, and what the formatter does and does not give us (read from ghostty's
 * src/terminal/formatter.zig at the pinned commit, then confirmed on the wire):
 *   - The terminal formatter always formats the ACTIVE screen. Its `modes` extra emits every
 *     mode that differs from the default BEFORE the content — so when a program is in the
 *     alternate screen, the output starts with CSI ?1049h and then paints the alt screen: the
 *     viewer is switched to its own alt screen and shown the program's frame. Correct.
 *   - The C API cannot reach the INACTIVE screen (ghostty_terminal_mode_set flips a flag without
 *     switching screens). So a client that attaches while the program is in the alt screen does
 *     not get the primary screen underneath. deckhold marks such a client "primary stale" and,
 *     the moment the program leaves the alt screen, sends it a second SNAPSHOT (now of the
 *     primary screen + scrollback). The viewer ends up exact either way.
 *   - Trailing blank rows are always trimmed, and a row whose cells carry only a background
 *     colour counts as blank. Formatting scrollback + active area in one pass would therefore
 *     leave the viewer's viewport misaligned with the final cursor CUP whenever the bottom rows
 *     are blank. So the snapshot is two passes: (1) the scrollback rows (history), then CRLF ×
 *     rows to push them all into the viewer's own scrollback; (2) CSI H and the active area,
 *     with every extra (modes, SGR, hyperlink, cursor, charsets, kitty keyboard, scrolling
 *     region, tabstops, pwd). Pass 2 positions rows from the top of the viewport, so trimming
 *     no longer matters. Since 610 pass 2 goes out in RUNS — a row with text and the rows with
 *     text it soft-wraps into — each placed with its own CUP: the formatter's `unwrap` loses a
 *     newline when a wrap meets an empty row (see send_snapshot), and a viewer then drew every
 *     row below it one row high. Guest/deckhold/test/snapshot-check.c replays snapshots and
 *     compares them with the holder's screen cell by cell (`make deckhold-snapshot-check`).
 *   - Two formatter extras are replaced by hand: `palette` emits all 256 OSC 4 entries (~6 KB,
 *     and it would repaint the viewer's own theme), so only entries a program changed are sent;
 *     and the terminal-level extras (DECSTBM homes the cursor, tabstops move it) come AFTER the
 *     cursor CUP, so the cursor is re-asserted at the very end. Known loss: background colour on text-less cells (a screen
 *     cleared with a background colour set comes back default-coloured until redrawn).
 *   - `select_all` is NOT used: it trims to the first/last non-whitespace cell, which would
 *     shift a full-screen program's layout up by its leading blank rows.
 *
 * WIRE (client ⇄ holder, both directions): frames [type u8][len u32 big-endian][payload].
 *   C→H  'H' HELLO  {cols u16, rows u16}  first frame; 0×0 means "keep the current size"
 *        'D' DATA   bytes for the program's stdin
 *        'R' RESIZE {cols u16, rows u16}
 *        'Q' QUERY  (no payload) — `deckhold ls`; answered with one 'I' INFO frame, then closed
 *        'P' DUMP   (no payload) — `deckhold dump`; one 'I' frame: the active screen as plain
 *                   text (one line per row) + a final "cursor=X,Y size=CxR screen=…" line
 *        'W' WATCH  (no payload; 612) — a status watcher: answered with one 'T' STATUS frame now and
 *                   another each time the program's root status record changes; it gets the EXIT
 *                   too, but never DATA or a SNAPSHOT, has no size and is not a viewer (not counted
 *                   in `clients`, never decides who answers a query). An older holder drops a client
 *                   that sends it (an unknown frame): the watcher then sees its pipe end with no
 *                   STATUS frame at all.
 *   H→C  'S' SNAPSHOT  VT bytes that reproduce the holder's screen on a blank terminal
 *        'D' DATA      the program's raw output
 *        'X' EXIT      {code u32}
 *        'I' INFO      one text line
 *        'N' NOSESSION (no payload) — sent by `deckhold pipe` only: no such session, never was
 *        'T' STATUS    (612) text: the root record's fields as in INFO
 *                      (`status=<report body>\tstatus_age=<seconds>`), or empty: no record
 * The protocol only ever grows by appending frame types; INFO lines only gain `key=value` fields placed
 * before the command (an older parser takes an unknown field for the command, which comes last).
 *
 * THE HOST TRANSPORT (`deckhold pipe -s NAME`): a verbatim byte relay between the pipe's stdio
 * and the session socket, so a host that runs it as a NON-terminal exec speaks this frame
 * protocol end to end (HELLO with its own size, RESIZE frames instead of a pty resize, SNAPSHOT /
 * DATA / EXIT as structured frames). If the session has already ended, the pipe answers with the
 * EXIT frame recorded in NAME.exit; if it never existed, with NOSESSION.
 *
 * WHEN NOBODY IS WATCHING: queries that need an answer (DSR cursor position, mode reports, …)
 * are answered by the attached viewer's terminal, which sees the raw bytes. With no viewer
 * attached deckhold answers them itself from the emulator (GHOSTTY_TERMINAL_OPT_WRITE_PTY), so a
 * program that asks while detached does not hang. (With two viewers attached both answer — the
 * same as tmux-less multi-attach anywhere; production would elect one.)
 *
 * HOW A PRODUCTION VERSION WOULD DIFFER
 *   - Transport. Here the Mac reaches the holder by exec-ing `deckhold attach` through vminitd
 *     with `terminal: true`, i.e. a SECOND pty inside the guest just to carry bytes, and that exec
 *     dies on every sleep to disk. Production Deck would dial the holder directly over vsock
 *     (one listener per guest, sessions multiplexed by id), speak this frame protocol end to end,
 *     and render the SNAPSHOT/DATA straight into its own libghostty surface — no second pty, no
 *     raw-mode relay, and a reconnect after wake is one vsock dial.
 *   - One holder per agent session (not one per sandbox), named by the session id; `ls` becomes
 *     a small RPC the host uses to rediscover sessions after an app restart.
 *   - Scrollback sizing. max_scrollback is BYTES (~1 KB per 120-col row, page-quantised; see
 *     TerminalVTReducer.swift). 10 MB ≈ 9,000 rows here. Production would size it per session,
 *     compress idle pages (ghostty_terminal_compress), and cap the snapshot it sends (e.g. the
 *     last N rows first, the rest on demand as the viewer scrolls).
 *   - The snapshot would be sent as structured data or at least compressed; a 9,000-row
 *     scrollback is a few MB of VT.
 *   - Viewer-size policy (smallest-wins vs last-wins), an elected query responder, per-client
 *     flow control with a resync SNAPSHOT instead of a disconnect, persistence of the scrollback
 *     across a guest reboot, and auth on the socket.
 *
 * BUILD: Guest/deckhold/build.sh (static aarch64-linux-musl; libghostty-vt from a pinned ghostty commit).
 * The file also builds on macOS (forkpty from <util.h>) for local experiments:
 *     clang -O2 -I<vt headers> deckhold.c libghostty-vt.a -lc++ -o deckhold  (DECKHOLD_DIR=/tmp/x)
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <util.h>
#else
#include <pty.h>
#endif

#include <ghostty/vt.h>

#define SUN_LEN_MAX sizeof(((struct sockaddr_un *)0)->sun_path)
#define MAX_CLIENTS 32
#define CLIENT_OUT_LIMIT (16u << 20)   /* a viewer this far behind is dropped; it reattaches */
#define RESNAP_DELAY_MS 120            /* a resize is followed by a fresh snapshot once it settles */

enum { F_HELLO = 'H', F_DATA = 'D', F_RESIZE = 'R', F_QUERY = 'Q', F_DUMP = 'P', F_WATCH = 'W',
       F_SNAPSHOT = 'S', F_EXIT = 'X', F_INFO = 'I', F_NOSESSION = 'N', F_STATUS = 'T' };

/* ── small helpers ──────────────────────────────────────────────────────────────────────── */

struct buf { uint8_t *p; size_t len, cap; };

static void buf_add(struct buf *b, const void *d, size_t n) {
    if (b->len + n > b->cap) {
        size_t c = b->cap ? b->cap : 4096;
        while (c < b->len + n) c *= 2;
        uint8_t *np = realloc(b->p, c);
        if (!np) { perror("realloc"); exit(70); }
        b->p = np; b->cap = c;
    }
    memcpy(b->p + b->len, d, n);
    b->len += n;
}
static void buf_str(struct buf *b, const char *s) { buf_add(b, s, strlen(s)); }
static void buf_drop(struct buf *b, size_t n) {
    memmove(b->p, b->p + n, b->len - n);
    b->len -= n;
}
static void buf_free(struct buf *b) { free(b->p); b->p = NULL; b->len = b->cap = 0; }

static void frame(struct buf *b, uint8_t type, const void *payload, uint32_t n) {
    uint8_t h[5] = { type, (uint8_t)(n >> 24), (uint8_t)(n >> 16), (uint8_t)(n >> 8), (uint8_t)n };
    buf_add(b, h, 5);
    if (n) buf_add(b, payload, n);
}

static uint16_t be16(const uint8_t *p) { return (uint16_t)(p[0] << 8 | p[1]); }
static uint32_t be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }

static int64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}
static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static void set_nonblock(int fd) { fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK); }

static bool write_all(int fd, const void *d, size_t n) {
    const uint8_t *p = d;
    while (n) {
        ssize_t w = write(fd, p, n);
        if (w < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN) { struct pollfd pf = { fd, POLLOUT, 0 }; poll(&pf, 1, 1000); continue; }
            return false;
        }
        p += w; n -= (size_t)w;
    }
    return true;
}

static const char *sock_dir(void) {
    const char *d = getenv("DECKHOLD_DIR");
    return d && *d ? d : "/run/deckhold";
}
static void sock_path(char *out, size_t n, const char *name) {
    if ((size_t)snprintf(out, n, "%s/%s.sock", sock_dir(), name) >= n) {
        fprintf(stderr, "deckhold: socket path %s/%s.sock is longer than sun_path allows\n", sock_dir(), name);
        exit(2);
    }
}

static void exit_path(char *out, size_t n, const char *name) {
    snprintf(out, n, "%s/%s.exit", sock_dir(), name);
}

/* A finished session leaves NAME.exit holding its exit code, so a late attach learns how it
 * ended instead of "no such session". Returns true and sets *code when the record exists. */
static bool read_exit_code(const char *name, int *code) {
    char path[300];
    exit_path(path, sizeof path, name);
    FILE *f = fopen(path, "r");
    if (!f) return false;
    bool ok = fscanf(f, "%d", code) == 1;
    fclose(f);
    return ok;
}

static int dial(const char *path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_un a = { .sun_family = AF_UNIX };
    snprintf(a.sun_path, sizeof a.sun_path, "%s", path);
    if (connect(fd, (struct sockaddr *)&a, sizeof a) != 0) { close(fd); return -1; }
    return fd;
}

/* ── the server ─────────────────────────────────────────────────────────────────────────── */

struct client {
    int fd;
    bool hello;          /* attached: receives DATA */
    bool primary_stale;  /* snapshotted while the alt screen was active: resend on leaving it */
    bool closing;        /* flush `out`, then close (QUERY answers) */
    bool watch;          /* sent WATCH: receives STATUS frames (never DATA — it is not a viewer) */
    int64_t resnap_at;   /* 0, or when to send a post-resize snapshot */
    struct buf in, out;
};

static struct {
    const char *name;
    char path[SUN_LEN_MAX];
    FILE *log;
    GhosttyTerminal term;
    int master;
    pid_t child;
    uint16_t cols, rows;
    struct buf master_out;          /* keystrokes (and detached query answers) for the program */
    struct client c[MAX_CLIENTS];
    int nclients;
    int sigpipe[2];                 /* SIGCHLD self-pipe */
    GhosttyTerminalScreen screen;   /* active screen after the last vt_write */
    uint64_t bytes_in;
    char cmdline[256];
} S;

static void logf_(const char *fmt, ...) {
    if (!S.log) return;
    time_t t = time(NULL);
    char ts[32];
    strftime(ts, sizeof ts, "%H:%M:%S", localtime(&t));
    fprintf(S.log, "%s ", ts);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(S.log, fmt, ap);
    va_end(ap);
    fputc('\n', S.log);
    fflush(S.log);
}

static int attached_count(void) {
    int n = 0;
    for (int i = 0; i < S.nclients; i++) n += S.c[i].hello;
    return n;
}

/* Effect callback: the emulator wants to answer a query (DSR, DECRQM, …). Only answer when no
 * viewer is attached — an attached viewer's own terminal sees the raw bytes and answers. */
static void on_write_pty(GhosttyTerminal t, void *ud, const uint8_t *d, size_t n) {
    (void)t; (void)ud;
    if (attached_count() == 0) buf_add(&S.master_out, d, n);
}

/* ── program status (OSC 7501) ──────────────────────────────────────────────────────────────
 *
 * A program reports what it is doing over its own pty: ESC ] 7501 ; key=value:key=value… ST (ST = ESC \
 * or BEL) — https://www.superlogical.com/rex/docs/build/program-status . Claude Code and pi report only
 * after the terminal answers the support query ESC ] 7501 ; ? ST, so deckhold is the consumer: it reads
 * every byte the program writes (attached or not), answers the query at once — always, whoever else
 * may — and keeps the session's records by the spec's rules. The bytes themselves are untouched: they
 * still reach the emulator and every viewer exactly as written.
 *
 * Rules kept (the spec's): a report REPLACES its record (keys left out are gone); `state=clear` removes the
 * record and everything under it, or every record with no id; a full reset (RIS, ESC c) removes every
 * record; ≤ 256 records, the least recently updated one dropped when full; a malformed pair is skipped, a
 * report over a limit, with bad base64 or control characters in its text, is discarded whole, as is one
 * with no known state or a bad id; unknown keys are ignored, the last of a duplicate key wins. `working`
 * and `blocked` end at the program's exit (the host drops them when the session ends).
 *
 * NOT handled: OSC 133 `A` (a new shell prompt also ends `working`/`blocked` in the spec). Claude Code
 * itself writes OSC 133 A when a turn starts — the same moment it reports `working` — and it sends a
 * report only when its status CHANGES, so dropping `working` at that A could lose a report the program
 * will not repeat. A session here runs one program (the agent), not a shell prompt.
 *
 * What is exposed: the ROOT record (no id) — in `deckhold ls`'s INFO line, and as STATUS frames pushed to
 * a client that sent WATCH (see WIRE above). Child records are kept (their clears and limits apply) but
 * not exposed. The text form (`status_fields`) is `status=<the record as a report body>\tstatus_age=<s>`,
 * the body canonical: state, app, kind, progress, msg, title, in that order, base64 padded. */

#define PS_MAX_RECORDS 256
#define PS_MAX_SEQUENCE 4096            /* the whole sequence, ESC ] … ST */
#define PS_MAX_BODY (PS_MAX_SEQUENCE - 9) /* minus "ESC ] 7501 ;" and the longest ST */

enum { PS_IDLE = 1, PS_WORKING, PS_DONE, PS_BLOCKED, PS_ERROR, PS_CLEAR };
static const char *const ps_states[] = { "", "idle", "working", "done", "blocked", "error", "clear" };
static const char *const ps_kinds[] = { "", "permission", "question", "auth" };

struct ps_record {
    bool used;
    char id[129];
    uint8_t state, kind;            /* kind: 0 none, else an index into ps_kinds */
    int progress;                   /* -1: none */
    char app[33];
    uint16_t msg_len;
    uint8_t title_len;
    char msg[2048], title[192];
    uint64_t seq;                   /* when it was last updated, as a counter (for the LRU drop) */
    double updated;                 /* the same, as monotonic seconds (for the age) */
};

static struct {
    struct ps_record r[PS_MAX_RECORDS];
    uint64_t seq;
    /* the scanner: where in an escape sequence the program's output is, across reads */
    enum { SC_GROUND, SC_ESC, SC_NUM, SC_BODY, SC_BODY_ESC } st;
    char num[8];
    uint8_t numlen;
    bool ours, over;                /* this OSC is 7501; it went over the limit */
    uint8_t body[PS_MAX_BODY];
    size_t len;
    uint64_t answered, applied, discarded;
    double window;                  /* the answers' rate limit: this second's start, and how many so far */
    int window_answers;
} PS;

/* At most this many answers a second: an answer that a terminal echoes back as OUTPUT (a pty with echo on and
 * no ECHOCTL) would be read as a new query — this keeps that loop from spinning. A program asks once. */
#define PS_ANSWERS_PER_SECOND 16

static void ps_root_changed(void);

static struct ps_record *ps_root(void) {
    for (int i = 0; i < PS_MAX_RECORDS; i++)
        if (PS.r[i].used && PS.r[i].id[0] == 0) return &PS.r[i];
    return NULL;
}

static void ps_clear_all(void) {
    bool had_root = ps_root() != NULL;
    for (int i = 0; i < PS_MAX_RECORDS; i++) PS.r[i].used = false;
    if (had_root) ps_root_changed();
}

static bool ps_in(uint8_t c, const char *set) { return c && strchr(set, c) != NULL; }
static bool ps_alnum(uint8_t c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'); }
/* [A-Za-z0-9_.+-] — an app name, an id segment */
static bool ps_name_char(uint8_t c) { return ps_alnum(c) || ps_in(c, "_.+-"); }

/* Standard base64, padding optional. Returns the decoded length, or -1 (bad input, or more than `cap`). */
static int ps_base64(const uint8_t *s, size_t n, char *out, size_t cap) {
    while (n && s[n - 1] == '=') n--;
    if (n % 4 == 1) return -1;
    uint32_t acc = 0;
    int bits = 0;
    size_t o = 0;
    for (size_t i = 0; i < n; i++) {
        uint8_t c = s[i];
        int v = c >= 'A' && c <= 'Z' ? c - 'A' : c >= 'a' && c <= 'z' ? c - 'a' + 26 : c >= '0' && c <= '9' ? c - '0' + 52
              : c == '+' ? 62 : c == '/' ? 63 : -1;
        if (v < 0) return -1;
        acc = acc << 6 | (uint32_t)v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            if (o >= cap) return -1;
            out[o++] = (char)(acc >> bits & 0xFF);
        }
    }
    return (int)o;
}

/* Decoded text may hold no control character: U+0000–U+001F, U+007F, U+0080–U+009F (C2 80–C2 9F). */
static bool ps_text_ok(const char *t, int n) {
    for (int i = 0; i < n; i++) {
        uint8_t c = (uint8_t)t[i];
        if (c < 0x20 || c == 0x7F) return false;
        if (c == 0xC2 && i + 1 < n && (uint8_t)t[i + 1] >= 0x80 && (uint8_t)t[i + 1] <= 0x9F) return false;
    }
    return true;
}

static bool ps_id_ok(const uint8_t *s, size_t n) {
    if (n == 0 || n > 128) return false;
    size_t seg = 0, levels = 1;
    for (size_t i = 0; i < n; i++) {
        if (s[i] == '/') {
            if (seg == 0 || ++levels > 8) return false;
            seg = 0;
        } else if (!ps_name_char(s[i]) || ++seg > 32) return false;
    }
    return seg > 0;
}

static void ps_trim(const uint8_t **s, size_t *n) {
    while (*n && ((*s)[0] == ' ' || (*s)[0] == '\t')) { (*s)++; (*n)--; }
    while (*n && ((*s)[*n - 1] == ' ' || (*s)[*n - 1] == '\t')) (*n)--;
}

static int ps_lookup(const uint8_t *v, size_t n, const char *const *names, int count) {
    for (int i = 1; i < count; i++)
        if (strlen(names[i]) == n && memcmp(names[i], v, n) == 0) return i;
    return 0;
}

/* One report (the body between "7501;" and ST). Every pair is checked before any record changes. */
struct ps_value { const uint8_t *v; size_t n; bool set; };

static void ps_report(const uint8_t *body, size_t len) {
    struct ps_value state = {0}, id = {0}, app = {0}, kind = {0}, progress = {0}, msg = {0}, title = {0};
    size_t at = 0;
    while (at <= len) {
        size_t end = at;
        while (end < len && body[end] != ':') end++;
        const uint8_t *p = body + at;
        size_t pn = end - at;
        at = end + 1;
        const uint8_t *eq = memchr(p, '=', pn);
        if (!eq) continue;                                  /* malformed: no '=' — skipped */
        const uint8_t *k = p, *v = eq + 1;
        size_t kn = (size_t)(eq - p), vn = pn - kn - 1;
        ps_trim(&k, &kn);
        ps_trim(&v, &vn);
        if (kn > 16) { PS.discarded++; return; }            /* a limit: the report is discarded whole */
        bool ok = kn > 0;
        for (size_t i = 0; i < kn; i++) ok = ok && k[i] >= 'a' && k[i] <= 'z';
        for (size_t i = 0; i < vn; i++) ok = ok && (ps_alnum(v[i]) || ps_in(v[i], "_.,+/=-"));
        if (!ok) continue;                                  /* malformed: skipped, the rest still counts */
        struct ps_value *slot = NULL;
        if (kn == 5 && !memcmp(k, "state", 5)) slot = &state;
        else if (kn == 2 && !memcmp(k, "id", 2)) slot = &id;
        else if (kn == 3 && !memcmp(k, "app", 3)) slot = &app;
        else if (kn == 4 && !memcmp(k, "kind", 4)) slot = &kind;
        else if (kn == 8 && !memcmp(k, "progress", 8)) slot = &progress;
        else if (kn == 3 && !memcmp(k, "msg", 3)) slot = &msg;
        else if (kn == 5 && !memcmp(k, "title", 5)) slot = &title;
        if (slot) { slot->v = v; slot->n = vn; slot->set = true; }    /* unknown keys ignored; the last one wins */
    }
    int st = state.set ? ps_lookup(state.v, state.n, ps_states, 7) : 0;
    if (!st) { PS.discarded++; return; }                    /* no known state: ignored */
    if (id.set && !ps_id_ok(id.v, id.n)) { PS.discarded++; return; }   /* a bad id never falls back to the root */
    if (app.set && app.n > 32) { PS.discarded++; return; }
    if (msg.set && msg.n > 2732) { PS.discarded++; return; }
    if (title.set && title.n > 256) { PS.discarded++; return; }
    char mbuf[2048], tbuf[192];
    int ml = 0, tl = 0;
    if (msg.set && ((ml = ps_base64(msg.v, msg.n, mbuf, sizeof mbuf)) < 0 || !ps_text_ok(mbuf, ml))) { PS.discarded++; return; }
    if (title.set && ((tl = ps_base64(title.v, title.n, tbuf, sizeof tbuf)) < 0 || !ps_text_ok(tbuf, tl))) { PS.discarded++; return; }
    PS.applied++;

    if (st == PS_CLEAR) {
        if (!id.set) { ps_clear_all(); return; }
        for (int i = 0; i < PS_MAX_RECORDS; i++) {
            struct ps_record *r = &PS.r[i];
            size_t rl = strlen(r->id);
            if (r->used && rl >= id.n && memcmp(r->id, id.v, id.n) == 0 && (rl == id.n || r->id[id.n] == '/')) r->used = false;
        }
        return;                                             /* an id is never the root: the root is unchanged */
    }
    struct ps_record *r = NULL, *lru = NULL;
    for (int i = 0; i < PS_MAX_RECORDS && !r; i++) {
        struct ps_record *x = &PS.r[i];
        if (x->used && strlen(x->id) == (id.set ? id.n : 0) && (!id.set || memcmp(x->id, id.v, id.n) == 0)) r = x;
    }
    for (int i = 0; i < PS_MAX_RECORDS && !r; i++) {
        struct ps_record *x = &PS.r[i];
        if (!x->used) r = x;
        else if (!lru || x->seq < lru->seq) lru = x;
    }
    bool dropped_root = false;
    if (!r) { r = lru; dropped_root = r->id[0] == 0; }      /* full: the least recently updated record goes */
    memset(r, 0, sizeof *r);
    r->used = true;
    if (id.set) memcpy(r->id, id.v, id.n);
    r->state = (uint8_t)st;
    r->progress = -1;
    if (app.set && app.n > 0) {
        bool ok = true;
        for (size_t i = 0; i < app.n; i++) ok = ok && ps_name_char(app.v[i]);
        if (ok) memcpy(r->app, app.v, app.n);               /* outside its set: as if absent */
    }
    if (kind.set && st == PS_BLOCKED) r->kind = (uint8_t)ps_lookup(kind.v, kind.n, ps_kinds, 4);
    if (progress.set && (st == PS_WORKING || st == PS_BLOCKED) && progress.n >= 1 && progress.n <= 3) {
        int pv = 0;
        bool digits = true;
        for (size_t i = 0; i < progress.n; i++) { digits = digits && progress.v[i] >= '0' && progress.v[i] <= '9'; pv = pv * 10 + (progress.v[i] - '0'); }
        if (digits && pv <= 100) r->progress = pv;
    }
    memcpy(r->msg, mbuf, (size_t)ml);
    r->msg_len = (uint16_t)ml;
    memcpy(r->title, tbuf, (size_t)tl);
    r->title_len = (uint8_t)tl;
    r->seq = ++PS.seq;
    r->updated = now_s();
    if (!id.set || dropped_root) ps_root_changed();
}

/* The query (a body starting with '?'): answered at once with the same body, whether or not a viewer's
 * terminal answers too (a program takes the first answer). */
static void ps_sequence_end(void) {
    if (PS.ours && !PS.over) {
        if (PS.len >= 1 && PS.body[0] == '?') {
            double t = now_s();
            if (t - PS.window >= 1.0) { PS.window = t; PS.window_answers = 0; }
            if (PS.window_answers < PS_ANSWERS_PER_SECOND) {
                buf_str(&S.master_out, "\x1b]7501;?\x1b\\");
                PS.window_answers++;
                PS.answered++;
            }
        } else {
            ps_report(PS.body, PS.len);
        }
    } else if (PS.ours) {
        PS.discarded++;
    }
    PS.st = SC_GROUND;
}

/* Every byte the program writes, in order, across reads — a sequence may be cut anywhere. */
static void ps_scan(const uint8_t *b, size_t n) {
    for (size_t i = 0; i < n; i++) {
        uint8_t c = b[i];
        switch (PS.st) {
        case SC_GROUND:
            if (c == 0x1B) PS.st = SC_ESC;
            break;
        case SC_ESC:
            if (c == ']') { PS.st = SC_NUM; PS.numlen = 0; PS.len = 0; PS.over = false; PS.ours = false; }
            else if (c == 'c') { PS.st = SC_GROUND; ps_clear_all(); }       /* RIS removes every record */
            else if (c != 0x1B) PS.st = SC_GROUND;
            break;
        case SC_NUM:
            if (c >= '0' && c <= '9') { if (PS.numlen < sizeof PS.num - 1) PS.num[PS.numlen++] = (char)c; else PS.numlen = sizeof PS.num; }
            else if (c == ';') { PS.ours = PS.numlen == 4 && memcmp(PS.num, "7501", 4) == 0; PS.st = SC_BODY; }
            else if (c == 0x07 || c == 0x18 || c == 0x1A) PS.st = SC_GROUND;
            else if (c == 0x1B) PS.st = SC_BODY_ESC;
            else PS.st = SC_BODY;                           /* not a number we know: skipped to its end */
            break;
        case SC_BODY:
            if (c == 0x07) ps_sequence_end();
            else if (c == 0x1B) PS.st = SC_BODY_ESC;
            else if (c == 0x18 || c == 0x1A) PS.st = SC_GROUND; /* CAN / SUB cancel the sequence */
            else if (PS.ours) { if (PS.len < PS_MAX_BODY) PS.body[PS.len++] = c; else PS.over = true; }
            break;
        case SC_BODY_ESC:
            if (c == '\\') ps_sequence_end();
            else { PS.st = SC_ESC; i--; }                   /* ESC + something else: the OSC is cut off; reread it */
            break;
        }
    }
}

/* The root record as INFO fields (`\tstatus=…\tstatus_age=…`, nothing when there is none). */
static void ps_fields(struct buf *out, bool leading_tab) {
    struct ps_record *r = ps_root();
    if (!r) return;
    static const char b64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    char tmp[64];
    if (leading_tab) buf_str(out, "\t");
    buf_str(out, "status=state=");
    buf_str(out, ps_states[r->state]);
    if (r->app[0]) { buf_str(out, ":app="); buf_str(out, r->app); }
    if (r->kind) { buf_str(out, ":kind="); buf_str(out, ps_kinds[r->kind]); }
    if (r->progress >= 0) { snprintf(tmp, sizeof tmp, ":progress=%d", r->progress); buf_str(out, tmp); }
    for (int which = 0; which < 2; which++) {
        const uint8_t *t = (const uint8_t *)(which ? r->title : r->msg);
        size_t n = which ? r->title_len : r->msg_len;
        if (!n) continue;
        buf_str(out, which ? ":title=" : ":msg=");
        for (size_t i = 0; i < n; i += 3) {
            uint32_t v = (uint32_t)t[i] << 16 | (i + 1 < n ? (uint32_t)t[i + 1] << 8 : 0) | (i + 2 < n ? t[i + 2] : 0);
            char q[4] = { b64[v >> 18 & 63], b64[v >> 12 & 63], i + 1 < n ? b64[v >> 6 & 63] : '=', i + 2 < n ? b64[v & 63] : '=' };
            buf_add(out, q, 4);
        }
    }
    snprintf(tmp, sizeof tmp, "\tstatus_age=%.0f", now_s() - r->updated);
    buf_str(out, tmp);
}

/* A STATUS frame: the root record's fields, or an empty payload (no record). */
static void ps_frame(struct buf *out) {
    struct buf s = {0};
    ps_fields(&s, false);
    frame(out, F_STATUS, s.p, (uint32_t)s.len);
    buf_free(&s);
}

/* The root record changed (set, replaced, cleared): every watcher is told at once. */
static void ps_root_changed(void) {
    for (int i = 0; i < S.nclients; i++)
        if (S.c[i].watch) ps_frame(&S.c[i].out);
}

static void resize_to(uint16_t cols, uint16_t rows) {
    if (!cols || !rows || (cols == S.cols && rows == S.rows)) return;
    struct winsize ws = { .ws_row = rows, .ws_col = cols };
    ioctl(S.master, TIOCSWINSZ, &ws);                       /* → SIGWINCH to the program */
    ghostty_terminal_resize(S.term, cols, rows, 8, 16);     /* → reflow (primary screen) */
    logf_("resize %ux%u → %ux%u", S.cols, S.rows, cols, rows);
    S.cols = cols; S.rows = rows;
}

static bool select_rows(GhosttyPointTag tag, uint32_t y0, uint32_t y1, GhosttySelection *sel) {
    memset(sel, 0, sizeof *sel);
    sel->size = sizeof *sel;
    sel->start.size = sel->end.size = sizeof(GhosttyGridRef);
    GhosttyPoint a = { .tag = tag, .value.coordinate = { .x = 0, .y = y0 } };
    GhosttyPoint b = { .tag = tag, .value.coordinate = { .x = (uint16_t)(S.cols - 1), .y = y1 } };
    return ghostty_terminal_grid_ref(S.term, a, &sel->start) == GHOSTTY_SUCCESS &&
           ghostty_terminal_grid_ref(S.term, b, &sel->end) == GHOSTTY_SUCCESS;
}

/* Whether row `y` (in `tag` coordinates) is soft-wrapped into the next. */
static bool row_wraps(GhosttyPointTag tag, uint32_t y) {
    GhosttyPoint p = { .tag = tag, .value.coordinate = { .x = 0, .y = y } };
    GhosttyGridRef r;
    memset(&r, 0, sizeof r);
    r.size = sizeof r;
    GhosttyRow row = 0;
    bool w = false;
    if (ghostty_terminal_grid_ref(S.term, p, &r) == GHOSTTY_SUCCESS && ghostty_grid_ref_row(&r, &row) == GHOSTTY_SUCCESS)
        ghostty_row_get(row, GHOSTTY_ROW_DATA_WRAP, &w);
    return w;
}

/* The width class of cell (x, y) of the active area (narrow, wide, spacer tail, spacer head). */
static int cell_wide(uint16_t x, uint32_t y) {
    GhosttyPoint p = { .tag = GHOSTTY_POINT_TAG_ACTIVE, .value.coordinate = { .x = x, .y = y } };
    GhosttyGridRef r;
    memset(&r, 0, sizeof r);
    r.size = sizeof r;
    GhosttyCell c = 0;
    GhosttyCellWide w = GHOSTTY_CELL_WIDE_NARROW;
    if (ghostty_terminal_grid_ref(S.term, p, &r) == GHOSTTY_SUCCESS && ghostty_grid_ref_cell(&r, &c) == GHOSTTY_SUCCESS)
        ghostty_cell_get(c, GHOSTTY_CELL_DATA_WIDE, &w);
    return (int)w;
}

/* Whether any cell of row `y` (active area) has text — what the formatter's "blank row" test asks. */
static bool row_has_text(uint32_t y) {
    for (uint16_t x = 0; x < S.cols; x++) {
        GhosttyPoint p = { .tag = GHOSTTY_POINT_TAG_ACTIVE, .value.coordinate = { .x = x, .y = y } };
        GhosttyGridRef r;
        memset(&r, 0, sizeof r);
        r.size = sizeof r;
        GhosttyCell c = 0;
        bool t = false;
        if (ghostty_terminal_grid_ref(S.term, p, &r) == GHOSTTY_SUCCESS && ghostty_grid_ref_cell(&r, &c) == GHOSTTY_SUCCESS &&
            ghostty_cell_get(c, GHOSTTY_CELL_DATA_HAS_TEXT, &t) == GHOSTTY_SUCCESS && t) return true;
    }
    return false;
}

/* One formatter pass over `sel` as VT. `modes` emits the terminal modes BEFORE the content (the formatter
 * always puts them first); `extras` the rest of the state, which the formatter puts AFTER the content
 * (cursor, pen, charsets, kitty keyboard; scrolling region, tabstops, pwd, keyboard). */
static bool format_into(struct buf *out, const GhosttySelection *sel, bool modes, bool extras) {
    GhosttyFormatterScreenExtra se;
    memset(&se, 0, sizeof se);
    se.size = sizeof se;                     /* every options struct is size-versioned */
    se.cursor = se.style = se.hyperlink = se.protection = se.kitty_keyboard = se.charsets = extras;
    GhosttyFormatterTerminalExtra te;
    memset(&te, 0, sizeof te);
    te.size = sizeof te;
    /* `palette` is left off: it emits all 256 entries (~6 KB), which would also overwrite the
     * viewer's own theme. send_snapshot emits only the entries a program actually changed. */
    te.modes = modes;
    te.scrolling_region = te.tabstops = te.pwd = te.keyboard = extras;
    te.screen = se;
    GhosttyFormatterTerminalOptions o;
    memset(&o, 0, sizeof o);
    o.size = sizeof o;
    o.emit = GHOSTTY_FORMATTER_FORMAT_VT;
    o.unwrap = true;       /* soft-wrapped rows go out as one line: the viewer re-wraps them itself,
                              so its own later reflow still knows they were one line */
    o.trim = false;
    o.extra = te;
    o.selection = sel;
    GhosttyFormatter f = NULL;
    if (ghostty_formatter_terminal_new(NULL, &f, S.term, o) != GHOSTTY_SUCCESS || !f) return false;
    uint8_t *p = NULL;
    size_t n = 0;
    bool ok = ghostty_formatter_format_alloc(f, NULL, &p, &n) == GHOSTTY_SUCCESS;
    if (ok && p) { buf_add(out, p, n); ghostty_free(NULL, p, n); }
    ghostty_formatter_free(f);
    return ok;
}

/* Build and queue a SNAPSHOT for client c: the holder's screen, reproduced on the viewer. */
static void send_snapshot(struct client *c, const char *why) {
    double t0 = now_s();
    struct buf s = {0};
    /* Leave any alt screen the viewer is in (it may still show the previous connection's alt
     * screen), full reset, clear the screen AND the viewer's scrollback: from here on the
     * viewer's contents are exactly ours. */
    buf_str(&s, "\x1b[?1049l\x1b" "c\x1b[H\x1b[2J\x1b[3J");

    size_t history = 0;
    ghostty_terminal_get(S.term, GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS, &history);
    GhosttyTerminalScreen scr = GHOSTTY_TERMINAL_SCREEN_PRIMARY;
    ghostty_terminal_get(S.term, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &scr);

    GhosttySelection sel;
    if (history > 0 && select_rows(GHOSTTY_POINT_TAG_HISTORY, 0, (uint32_t)(history - 1), &sel)) {
        /* Pass 1: scrollback. Then scroll it all off the viewport into the viewer's scrollback. */
        format_into(&s, &sel, false, false);
        buf_str(&s, "\x1b[0m");
        for (unsigned i = 0; i < S.rows; i++) buf_str(&s, "\r\n");
    }
    const size_t active_at = s.len;
    /* Pass 2: the active area from the top-left, with every piece of terminal state — in RUNS placed at
     * their own rows (610). The formatter's `unwrap` joins a soft-wrapped row with the next and counts the
     * line's newline only at its last row; but an empty row (no text) is a "blank row" to it, counted
     * before that test — so a wrap into or out of an empty row lost a newline and everything below it
     * landed a row high on the viewer (609: after a narrowing reflow a TUI's prompt sat a row off in the
     * web pane until it redrew). A run is a row with text and the rows with text it soft-wraps into; each
     * starts with a CUP to its own row, so the viewer's rows are the holder's whatever the formatter
     * counts, and within a run the viewer still wraps the line itself (its later reflow knows it was one
     * line). Empty rows need nothing: the viewer was cleared. The modes go out with the first run (before
     * any content: ?1049h must come before the alt screen's rows), the rest of the state with the last
     * (after all content: it ends with the cursor and the pen). */
    buf_str(&s, "\x1b[H");
    uint32_t starts[1001], nstarts = 0;
    bool text_above = false;
    for (uint32_t y = 0; y < S.rows && nstarts < 1001; y++) {
        bool text = row_has_text(y);
        /* A row ending in a spacer head whose wide character is no longer at the start of the next row
         * (erased or overwritten since it wrapped) also breaks a run: the formatter skips the spacer
         * without counting it, and the blanks that follow it would land one column early. */
        bool orphan_head = y > 0 && cell_wide((uint16_t)(S.cols - 1), y - 1) == GHOSTTY_CELL_WIDE_SPACER_HEAD &&
                           cell_wide(0, y) != GHOSTTY_CELL_WIDE_WIDE;
        if (y == 0 || orphan_head || !(text && text_above && row_wraps(GHOSTTY_POINT_TAG_ACTIVE, y - 1))) starts[nstarts++] = y;
        text_above = text;
    }
    bool ok = nstarts > 0;
    for (uint32_t i = 0; ok && i < nstarts; i++) {
        uint32_t a = starts[i], b = i + 1 < nstarts ? starts[i + 1] - 1 : (uint32_t)(S.rows - 1);
        if (i > 0) {
            char at[32];
            snprintf(at, sizeof at, "\x1b[0m\x1b[%u;1H", a + 1);
            buf_str(&s, at);
        }
        ok = select_rows(GHOSTTY_POINT_TAG_ACTIVE, a, b, &sel);
        /* A run that ends on a spacer head (an orphan — see above): the formatter, unwrapping, would extend
         * the selection to the first cell of the next row (where it expects the wide character); stop it at
         * the cell before. */
        if (ok && S.cols > 1 && cell_wide((uint16_t)(S.cols - 1), b) == GHOSTTY_CELL_WIDE_SPACER_HEAD) {
            GhosttyPoint e = { .tag = GHOSTTY_POINT_TAG_ACTIVE, .value.coordinate = { .x = (uint16_t)(S.cols - 2), .y = b } };
            ok = ghostty_terminal_grid_ref(S.term, e, &sel.end) == GHOSTTY_SUCCESS;
        }
        ok = ok && format_into(&s, &sel, i == 0, i + 1 == nstarts);
    }
    if (!ok) {
        /* A row could not be addressed (never seen): the whole area in one pass, as before 610. */
        s.len = active_at;
        if (select_rows(GHOSTTY_POINT_TAG_ACTIVE, 0, (uint32_t)(S.rows - 1), &sel)) format_into(&s, &sel, true, true);
        else format_into(&s, NULL, true, true);
    }

    /* The terminal-level extras (DECSTBM homes the cursor; tabstops move it with CHA) are
     * emitted AFTER the screen's cursor CUP, so the cursor must be put back last. */
    uint16_t cx = 0, cy = 0;
    ghostty_terminal_get(S.term, GHOSTTY_TERMINAL_DATA_CURSOR_X, &cx);
    ghostty_terminal_get(S.term, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &cy);
    char cup[32];
    snprintf(cup, sizeof cup, "\x1b[%u;%uH", cy + 1u, cx + 1u);
    buf_str(&s, cup);

    /* Colours a program set (OSC 4 / 10 / 11 / 12) — only those that differ from the default. */
    GhosttyColorRgb pal[256], def[256];
    if (ghostty_terminal_get(S.term, GHOSTTY_TERMINAL_DATA_COLOR_PALETTE, pal) == GHOSTTY_SUCCESS &&
        ghostty_terminal_get(S.term, GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT, def) == GHOSTTY_SUCCESS)
        for (int i = 0; i < 256; i++)
            if (memcmp(&pal[i], &def[i], sizeof pal[i]) != 0) {
                char o[48];
                snprintf(o, sizeof o, "\x1b]4;%d;rgb:%02x/%02x/%02x\x1b\\", i, pal[i].r, pal[i].g, pal[i].b);
                buf_str(&s, o);
            }
    static const struct { GhosttyTerminalData eff, dflt; int osc; } dyn[] = {
        { GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND, GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND_DEFAULT, 10 },
        { GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND, GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND_DEFAULT, 11 },
        { GHOSTTY_TERMINAL_DATA_COLOR_CURSOR, GHOSTTY_TERMINAL_DATA_COLOR_CURSOR_DEFAULT, 12 },
    };
    for (size_t i = 0; i < sizeof dyn / sizeof dyn[0]; i++) {
        GhosttyColorRgb e, d;
        if (ghostty_terminal_get(S.term, dyn[i].eff, &e) != GHOSTTY_SUCCESS) continue;
        if (ghostty_terminal_get(S.term, dyn[i].dflt, &d) == GHOSTTY_SUCCESS && !memcmp(&e, &d, sizeof e)) continue;
        char o[48];
        snprintf(o, sizeof o, "\x1b]%d;rgb:%02x/%02x/%02x\x1b\\", dyn[i].osc, e.r, e.g, e.b);
        buf_str(&s, o);
    }

    GhosttyString title = {0};
    if (ghostty_terminal_get(S.term, GHOSTTY_TERMINAL_DATA_TITLE, &title) == GHOSTTY_SUCCESS && title.len) {
        buf_str(&s, "\x1b]2;");
        buf_add(&s, title.ptr, title.len);
        buf_str(&s, "\x07");
    }

    frame(&c->out, F_SNAPSHOT, s.p, (uint32_t)s.len);
    c->primary_stale = scr == GHOSTTY_TERMINAL_SCREEN_ALTERNATE;
    logf_("snapshot (%s) → fd %d: %zu bytes, %ux%u, %s screen, %zu history rows, built in %.2f ms",
          why, c->fd, s.len, S.cols, S.rows, scr == GHOSTTY_TERMINAL_SCREEN_ALTERNATE ? "alt" : "primary",
          history, (now_s() - t0) * 1000);
    buf_free(&s);
}

static void info_line(struct buf *out) {
    GhosttyTerminalScreen scr = GHOSTTY_TERMINAL_SCREEN_PRIMARY;
    ghostty_terminal_get(S.term, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &scr);
    size_t history = 0;
    ghostty_terminal_get(S.term, GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS, &history);
    char line[512];
    snprintf(line, sizeof line, "%s\tpid=%d\tsize=%ux%u\tclients=%d\tscreen=%s\thistory=%zu\tbytes=%llu",
             S.name, (int)S.child, S.cols, S.rows, attached_count(),
             scr == GHOSTTY_TERMINAL_SCREEN_ALTERNATE ? "alt" : "primary", history, (unsigned long long)S.bytes_in);
    struct buf s = {0};
    buf_str(&s, line);
    ps_fields(&s, true);              /* 612: the program's status — BEFORE the command, which is the last field */
    buf_str(&s, "\t");
    buf_str(&s, S.cmdline);
    frame(out, F_INFO, s.p, (uint32_t)s.len);
    buf_free(&s);
}

/* The active screen as plain text, row by row — for tests and for eyeballing the model. */
static void dump_screen(struct buf *out) {
    struct buf s = {0};
    GhosttyFormatterTerminalOptions o;
    memset(&o, 0, sizeof o);
    o.size = sizeof o;
    o.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
    o.extra.size = sizeof o.extra;
    o.extra.screen.size = sizeof o.extra.screen;
    GhosttySelection sel;
    o.selection = select_rows(GHOSTTY_POINT_TAG_ACTIVE, 0, (uint32_t)(S.rows - 1), &sel) ? &sel : NULL;
    o.trim = true;
    GhosttyFormatter f = NULL;
    if (ghostty_formatter_terminal_new(NULL, &f, S.term, o) == GHOSTTY_SUCCESS && f) {
        uint8_t *p = NULL;
        size_t n = 0;
        if (ghostty_formatter_format_alloc(f, NULL, &p, &n) == GHOSTTY_SUCCESS && p) { buf_add(&s, p, n); ghostty_free(NULL, p, n); }
        ghostty_formatter_free(f);
    }
    uint16_t cx = 0, cy = 0;
    ghostty_terminal_get(S.term, GHOSTTY_TERMINAL_DATA_CURSOR_X, &cx);
    ghostty_terminal_get(S.term, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &cy);
    GhosttyTerminalScreen scr = GHOSTTY_TERMINAL_SCREEN_PRIMARY;
    ghostty_terminal_get(S.term, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &scr);
    char tail[96];
    snprintf(tail, sizeof tail, "\ncursor=%u,%u size=%ux%u screen=%s", cx, cy, S.cols, S.rows,
             scr == GHOSTTY_TERMINAL_SCREEN_ALTERNATE ? "alt" : "primary");
    buf_str(&s, tail);
    frame(out, F_INFO, s.p, (uint32_t)s.len);
    buf_free(&s);
}

static void drop_client(int i) {
    logf_("client fd %d gone", S.c[i].fd);
    close(S.c[i].fd);
    buf_free(&S.c[i].in);
    buf_free(&S.c[i].out);
    S.c[i] = S.c[--S.nclients];
}

/* Parse complete frames from a client. Returns false if the client must be dropped. */
static bool client_frames(struct client *c) {
    while (c->in.len >= 5) {
        uint32_t n = be32(c->in.p + 1);
        if (n > (1u << 24)) return false;
        if (c->in.len < 5 + n) break;
        uint8_t t = c->in.p[0];
        const uint8_t *p = c->in.p + 5;
        switch (t) {
        case F_HELLO:
            if (n >= 4) resize_to(be16(p), be16(p + 2));
            logf_("hello fd %d at %ux%u", c->fd, n >= 4 ? be16(p) : 0, n >= 4 ? be16(p + 2) : 0);
            send_snapshot(c, "attach");
            c->hello = true;
            break;
        case F_DATA:
            buf_add(&S.master_out, p, n);
            break;
        case F_RESIZE:
            if (n >= 4 && (be16(p) != S.cols || be16(p + 2) != S.rows)) {
                resize_to(be16(p), be16(p + 2));
                if (c->hello) c->resnap_at = now_ms() + RESNAP_DELAY_MS;
            }
            break;
        case F_DUMP:
            dump_screen(&c->out);
            c->closing = true;
            break;
        case F_QUERY:
            info_line(&c->out);
            c->closing = true;
            break;
        case F_WATCH:                 /* 612: a status watcher — the current root record now, then every change */
            c->watch = true;
            ps_frame(&c->out);
            logf_("watch fd %d", c->fd);
            break;
        default:
            return false;
        }
        buf_drop(&c->in, 5 + n);
    }
    return true;
}

static void reset_signals(void);

/* SIGCHLD → 'c', SIGTERM/SIGINT/SIGHUP → 't' (hang up the program; its exit ends the holder). */
static void on_signal(int sig) {
    int e = errno;
    ssize_t r = write(S.sigpipe[1], sig == SIGCHLD ? "c" : "t", 1);
    (void)r;
    errno = e;
}

/* The program is gone: flush what it said, tell the viewers, clean up. */
static void finish(int status) {
    int code = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + (WIFSIGNALED(status) ? WTERMSIG(status) : 0);
    logf_("program exited, code %d", code);
    {
        char ep[300];
        exit_path(ep, sizeof ep, S.name);
        FILE *ef = fopen(ep, "w");
        if (ef) { fprintf(ef, "%d\n", code); fclose(ef); }
    }
    uint8_t cb[4] = { (uint8_t)(code >> 24), (uint8_t)(code >> 16), (uint8_t)(code >> 8), (uint8_t)code };
    for (int i = 0; i < S.nclients; i++) {
        if (S.c[i].hello || S.c[i].watch) frame(&S.c[i].out, F_EXIT, cb, 4);
        write_all(S.c[i].fd, S.c[i].out.p, S.c[i].out.len);
        close(S.c[i].fd);
    }
    unlink(S.path);
    exit(0);
}

/* Read everything the master has right now; feed the emulator and the viewers. Returns false at EOF. */
static bool pump_master(void) {
    uint8_t b[65536];
    for (int rounds = 0; rounds < 16; rounds++) {
        ssize_t n = read(S.master, b, sizeof b);
        if (n < 0 && (errno == EAGAIN || errno == EINTR)) return true;
        if (n <= 0) return false;        /* EIO: every slave fd closed */
        S.bytes_in += (uint64_t)n;
        ps_scan(b, (size_t)n);        /* 612: OSC 7501 — reads the bytes, changes none of them */
        ghostty_terminal_vt_write(S.term, b, (size_t)n);
        GhosttyTerminalScreen scr = GHOSTTY_TERMINAL_SCREEN_PRIMARY;
        ghostty_terminal_get(S.term, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &scr);
        bool left_alt = S.screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE && scr == GHOSTTY_TERMINAL_SCREEN_PRIMARY;
        S.screen = scr;
        for (int i = 0; i < S.nclients; i++) {
            struct client *c = &S.c[i];
            if (!c->hello) continue;
            frame(&c->out, F_DATA, b, (uint32_t)n);
            /* The viewer attached during the alt screen never saw our primary screen: now that
             * the program is back on it, replace the viewer's (stale) primary with ours. */
            if (left_alt && c->primary_stale) send_snapshot(c, "left the alt screen");
        }
        if ((size_t)n < sizeof b) return true;
    }
    return true;
}

static int serve(int argc, char **argv, const char *name, uint16_t cols, uint16_t rows,
                 size_t scrollback, bool foreground) {
    S.name = name;
    S.cols = cols; S.rows = rows;
    sock_path(S.path, sizeof S.path, name);
    for (int i = 0, off = 0; i < argc && off < (int)sizeof S.cmdline - 2; i++)
        off += snprintf(S.cmdline + off, sizeof S.cmdline - off, "%s%s", i ? " " : "", argv[i]);

    mkdir(sock_dir(), 0700);
    int probe = dial(S.path);
    if (probe >= 0) { close(probe); fprintf(stderr, "deckhold: session %s already exists\n", name); return 1; }
    unlink(S.path);
    {
        char ep[300];
        exit_path(ep, sizeof ep, name);
        unlink(ep);                     /* a new session under an old name starts un-ended */
    }

    /* Daemonize: the parent returns only once the socket is listening, so a caller can attach
     * immediately after `deckhold serve` exits. */
    int ready[2] = { -1, -1 };
    if (!foreground) {
        if (pipe(ready) != 0) { perror("pipe"); return 1; }
        pid_t p = fork();
        if (p < 0) { perror("fork"); return 1; }
        if (p > 0) {
            close(ready[1]);
            char ok = 0;
            ssize_t r = read(ready[0], &ok, 1);
            if (r == 1 && ok == 'k') return 0;
            fprintf(stderr, "deckhold: server failed to start (see %s/%s.log)\n", sock_dir(), name);
            return 1;
        }
        close(ready[0]);
        setsid();
        int dn = open("/dev/null", O_RDWR);
        dup2(dn, 0); dup2(dn, 1); dup2(dn, 2);
        if (dn > 2) close(dn);
    }
    char logpath[160];
    snprintf(logpath, sizeof logpath, "%s/%s.log", sock_dir(), name);
    S.log = fopen(logpath, "a");

    signal(SIGPIPE, SIG_IGN);
    if (pipe(S.sigpipe) != 0) return 1;
    set_nonblock(S.sigpipe[0]); set_nonblock(S.sigpipe[1]);
    struct sigaction sa = { .sa_handler = on_signal, .sa_flags = SA_RESTART | SA_NOCLDSTOP };
    sigaction(SIGCHLD, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGHUP, &sa, NULL);

    int lfd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un a = { .sun_family = AF_UNIX };
    snprintf(a.sun_path, sizeof a.sun_path, "%s", S.path);
    if (lfd < 0 || bind(lfd, (struct sockaddr *)&a, sizeof a) != 0 || listen(lfd, 16) != 0) {
        logf_("listen on %s failed: %s", S.path, strerror(errno));
        return 1;
    }
    chmod(S.path, 0600);
    set_nonblock(lfd);

    GhosttyTerminalOptions to = { .cols = cols, .rows = rows, .max_scrollback = scrollback };
    if (ghostty_terminal_new(NULL, &S.term, to) != GHOSTTY_SUCCESS) { logf_("ghostty_terminal_new failed"); return 1; }
    ghostty_terminal_set(S.term, GHOSTTY_TERMINAL_OPT_WRITE_PTY, (const void *)on_write_pty);
    S.screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY;

    struct winsize ws = { .ws_row = rows, .ws_col = cols };
    S.child = forkpty(&S.master, NULL, NULL, &ws);
    if (S.child < 0) { logf_("forkpty: %s", strerror(errno)); return 1; }
    if (S.child == 0) {
        setenv("TERM", "xterm-256color", 1);
        /* 599: the session's own terminal, for a helper that has lost its controlling terminal (a
         * browser opener that setsid()s its child) and still has something to say to the viewer —
         * the xdg-open shim of the browser bridge writes its marker here. */
        { const char *tty = ttyname(0); if (tty) setenv("DOZ_TTY", tty, 1); }
        reset_signals();
        execvp(argv[0], argv);
        fprintf(stderr, "deckhold: exec %s: %s\n", argv[0], strerror(errno));
        _exit(127);
    }
    set_nonblock(S.master);
    logf_("serving %s: pid %d, %ux%u, scrollback %zu bytes: %s", S.path, (int)S.child, cols, rows, scrollback, S.cmdline);
    if (!foreground) { ssize_t r = write(ready[1], "k", 1); (void)r; close(ready[1]); }

    bool master_eof = false;
    for (;;) {
        struct pollfd pf[3 + MAX_CLIENTS];
        int np = 0;
        pf[np++] = (struct pollfd){ S.sigpipe[0], POLLIN, 0 };
        pf[np++] = (struct pollfd){ lfd, POLLIN, 0 };
        pf[np++] = (struct pollfd){ master_eof ? -1 : S.master,
                                    (short)(POLLIN | (S.master_out.len ? POLLOUT : 0)), 0 };
        int64_t next = -1;
        for (int i = 0; i < S.nclients; i++) {
            pf[np++] = (struct pollfd){ S.c[i].fd, (short)(POLLIN | (S.c[i].out.len ? POLLOUT : 0)), 0 };
            if (S.c[i].resnap_at && (next < 0 || S.c[i].resnap_at < next)) next = S.c[i].resnap_at;
        }
        int timeout = next < 0 ? -1 : (int)(next > now_ms() ? next - now_ms() : 0);
        if (poll(pf, (nfds_t)np, timeout) < 0 && errno != EINTR) { logf_("poll: %s", strerror(errno)); return 1; }

        /* The program. */
        if (pf[2].revents & (POLLIN | POLLHUP | POLLERR)) {
            if (!pump_master()) master_eof = true;
        }
        if (!master_eof && (pf[2].revents & POLLOUT) && S.master_out.len) {
            ssize_t w = write(S.master, S.master_out.p, S.master_out.len);
            if (w > 0) buf_drop(&S.master_out, (size_t)w);
        }
        if (pf[0].revents & POLLIN) {
            char tmp[64];
            ssize_t n;
            while ((n = read(S.sigpipe[0], tmp, sizeof tmp)) > 0)
                if (memchr(tmp, 't', (size_t)n)) { logf_("terminated: hanging up the program"); kill(S.child, SIGHUP); }
        }
        {
            int status;
            pid_t r = waitpid(S.child, &status, master_eof ? 0 : WNOHANG);
            if (r == S.child) {
                while (!master_eof && pump_master()) {
                    struct pollfd m = { S.master, POLLIN, 0 };
                    if (poll(&m, 1, 0) <= 0) break;
                }
                finish(status);
            }
        }

        /* New viewers. */
        if (pf[1].revents & POLLIN) {
            for (;;) {
                int cfd = accept(lfd, NULL, NULL);
                if (cfd < 0) break;
                if (S.nclients == MAX_CLIENTS) { close(cfd); continue; }
                set_nonblock(cfd);
                S.c[S.nclients++] = (struct client){ .fd = cfd };
                logf_("client fd %d connected", cfd);
            }
        }

        /* Viewers: input, output. Walk backwards so drop_client's swap-remove is safe; pollfd
         * index 3+i matches client i only for clients that existed when poll() was built. */
        int polled = np - 3;
        for (int i = S.nclients - 1; i >= 0; i--) {
            struct client *c = &S.c[i];
            short re = i < polled ? pf[3 + i].revents : 0;
            bool drop = false;
            if (re & (POLLIN | POLLHUP | POLLERR)) {
                uint8_t b[16384];
                ssize_t n = read(c->fd, b, sizeof b);
                if (n > 0) { buf_add(&c->in, b, (size_t)n); drop = !client_frames(c); }
                else if (n == 0 || (errno != EAGAIN && errno != EINTR)) drop = true;
            }
            if (!drop && c->resnap_at && now_ms() >= c->resnap_at) {
                c->resnap_at = 0;
                send_snapshot(c, "resize settled");
            }
            if (!drop && c->out.len) {
                ssize_t w = write(c->fd, c->out.p, c->out.len);
                if (w > 0) buf_drop(&c->out, (size_t)w);
                else if (w < 0 && errno != EAGAIN && errno != EINTR) drop = true;
                if (c->out.len > CLIENT_OUT_LIMIT) { logf_("client fd %d too slow", c->fd); drop = true; }
            }
            if (!drop && c->closing && c->out.len == 0) drop = true;
            if (drop) drop_client(i);
        }
    }
}

/* ── the client ─────────────────────────────────────────────────────────────────────────── */

static struct termios saved_tio;
static bool tio_saved;
static int winch_pipe[2];

static void restore_tty(void) { if (tio_saved) tcsetattr(STDIN_FILENO, TCSANOW, &saved_tio); }
static void on_winch(int sig) { (void)sig; int e = errno; ssize_t r = write(winch_pipe[1], "w", 1); (void)r; errno = e; }

static void send_size(int fd, uint8_t type) {
    struct winsize ws = {0};
    ioctl(STDIN_FILENO, TIOCGWINSZ, &ws);
    uint8_t p[4] = { (uint8_t)(ws.ws_col >> 8), (uint8_t)ws.ws_col, (uint8_t)(ws.ws_row >> 8), (uint8_t)ws.ws_row };
    struct buf b = {0};
    frame(&b, type, p, 4);
    write_all(fd, b.p, b.len);
    buf_free(&b);
}

static int attach(const char *name) {
    char path[SUN_LEN_MAX];
    sock_path(path, sizeof path, name);
    int fd = dial(path);
    if (fd < 0) { fprintf(stderr, "deckhold: no session %s (%s)\n", name, path); return 1; }
    signal(SIGPIPE, SIG_IGN);

    if (isatty(STDIN_FILENO) && tcgetattr(STDIN_FILENO, &saved_tio) == 0) {
        tio_saved = true;
        struct termios raw = saved_tio;
        cfmakeraw(&raw);
        tcsetattr(STDIN_FILENO, TCSANOW, &raw);
        atexit(restore_tty);
    }
    if (pipe(winch_pipe) != 0) return 1;
    set_nonblock(winch_pipe[0]); set_nonblock(winch_pipe[1]);
    struct sigaction sa = { .sa_handler = on_winch, .sa_flags = SA_RESTART };
    sigaction(SIGWINCH, &sa, NULL);

    /* An exec'd pty can start at 0×0 and be sized a moment later: wait briefly for that first
     * SIGWINCH so HELLO carries the real size (0×0 would keep the holder's current size). */
    struct winsize ws = {0};
    ioctl(STDIN_FILENO, TIOCGWINSZ, &ws);
    if (!ws.ws_col || !ws.ws_row) {
        struct pollfd w = { winch_pipe[0], POLLIN, 0 };
        poll(&w, 1, 500);
    }
    send_size(fd, F_HELLO);

    struct buf in = {0};
    bool stdin_open = true;
    for (;;) {
        struct pollfd pf[3] = {
            { fd, POLLIN, 0 },
            { stdin_open ? STDIN_FILENO : -1, POLLIN, 0 },
            { winch_pipe[0], POLLIN, 0 },
        };
        if (poll(pf, 3, -1) < 0) { if (errno == EINTR) continue; break; }
        if (pf[2].revents & POLLIN) {
            char tmp[64];
            while (read(winch_pipe[0], tmp, sizeof tmp) > 0) {}
            send_size(fd, F_RESIZE);
        }
        if (pf[1].revents & (POLLIN | POLLHUP)) {
            uint8_t b[4096];
            ssize_t n = read(STDIN_FILENO, b, sizeof b);
            if (n > 0) {
                struct buf f = {0};
                frame(&f, F_DATA, b, (uint32_t)n);
                bool ok = write_all(fd, f.p, f.len);
                buf_free(&f);
                if (!ok) break;
            } else if (n == 0 || errno != EINTR) stdin_open = false;
        }
        if (pf[0].revents & (POLLIN | POLLHUP | POLLERR)) {
            uint8_t b[65536];
            ssize_t n = read(fd, b, sizeof b);
            if (n <= 0) break;                       /* holder gone (or the host closed us) */
            buf_add(&in, b, (size_t)n);
            while (in.len >= 5) {
                uint32_t len = be32(in.p + 1);
                if (in.len < 5 + len) break;
                uint8_t t = in.p[0];
                if (t == F_SNAPSHOT || t == F_DATA) {
                    if (!write_all(STDOUT_FILENO, in.p + 5, len)) return 0;
                } else if (t == F_EXIT) {
                    int code = len >= 4 ? (int)be32(in.p + 5) : 0;
                    return code;
                }
                buf_drop(&in, 5 + len);
            }
        }
    }
    return 0;
}

/* ── pipe: the host's transport ─────────────────────────────────────────────────────────── */

/* A verbatim relay: stdin → session socket, session socket → stdout. No tty, no framing of its
 * own — the host writes HELLO/DATA/RESIZE frames and reads SNAPSHOT/DATA/EXIT frames through it.
 * stdin EOF (the host detached) or socket EOF (the holder closed us) ends it. */
static int pipe_mode(const char *name) {
    char path[SUN_LEN_MAX];
    sock_path(path, sizeof path, name);
    signal(SIGPIPE, SIG_IGN);
    int fd = dial(path);
    if (fd < 0) {
        struct buf b = {0};
        int code = 0;
        if (read_exit_code(name, &code)) {
            uint8_t cb[4] = { (uint8_t)(code >> 24), (uint8_t)(code >> 16), (uint8_t)(code >> 8), (uint8_t)code };
            frame(&b, F_EXIT, cb, 4);
        } else {
            frame(&b, F_NOSESSION, NULL, 0);
        }
        write_all(STDOUT_FILENO, b.p, b.len);
        buf_free(&b);
        return 0;
    }
    bool stdin_open = true;
    for (;;) {
        struct pollfd pf[2] = { { fd, POLLIN, 0 }, { stdin_open ? STDIN_FILENO : -1, POLLIN, 0 } };
        if (poll(pf, 2, -1) < 0) { if (errno == EINTR) continue; break; }
        if (pf[1].revents & (POLLIN | POLLHUP | POLLERR)) {
            uint8_t b[16384];
            ssize_t n = read(STDIN_FILENO, b, sizeof b);
            if (n > 0) { if (!write_all(fd, b, (size_t)n)) break; }
            else if (n == 0 || (errno != EINTR && errno != EAGAIN)) break;   /* host detached */
        }
        if (pf[0].revents & (POLLIN | POLLHUP | POLLERR)) {
            uint8_t b[65536];
            ssize_t n = read(fd, b, sizeof b);
            if (n <= 0) break;                                               /* holder closed us */
            if (!write_all(STDOUT_FILENO, b, (size_t)n)) break;
        }
    }
    close(fd);
    return 0;
}

/* ── ls ─────────────────────────────────────────────────────────────────────────────────── */

/* Send one no-payload request frame, return the payload of the 'I' answer (malloc'd) or NULL. */
static char *request(const char *path, uint8_t type) {
    int fd = dial(path);
    if (fd < 0) return NULL;
    struct buf q = {0};
    frame(&q, type, NULL, 0);
    write_all(fd, q.p, q.len);
    buf_free(&q);
    struct buf in = {0};
    uint8_t b[16384];
    ssize_t r;
    while ((r = read(fd, b, sizeof b)) > 0) buf_add(&in, b, (size_t)r);
    close(fd);
    char *res = NULL;
    if (in.len >= 5 && in.p[0] == F_INFO && in.len >= 5 + be32(in.p + 1)) {
        uint32_t n = be32(in.p + 1);
        res = malloc(n + 1);
        memcpy(res, in.p + 5, n);
        res[n] = 0;
    }
    buf_free(&in);
    return res;
}

static int dump(const char *name) {
    char path[SUN_LEN_MAX];
    sock_path(path, sizeof path, name);
    char *s = request(path, F_DUMP);
    if (!s) { fprintf(stderr, "deckhold: no session %s\n", name); return 1; }
    printf("%s\n", s);
    free(s);
    return 0;
}

static int ls(void) {
    DIR *d = opendir(sock_dir());
    if (!d) return 0;
    struct dirent *e;
    while ((e = readdir(d))) {
        size_t n = strlen(e->d_name);
        if (n > 5 && strcmp(e->d_name + n - 5, ".exit") == 0) {
            /* An ended session: listed only when its socket is gone (it always is, once ended). */
            char nm[256], sp[300];
            snprintf(nm, sizeof nm, "%.*s", (int)(n - 5), e->d_name);
            snprintf(sp, sizeof sp, "%s/%s.sock", sock_dir(), nm);
            int code = 0;
            if (access(sp, F_OK) != 0 && read_exit_code(nm, &code)) printf("%s\tended=%d\n", nm, code);
            continue;
        }
        if (n < 6 || strcmp(e->d_name + n - 5, ".sock") != 0) continue;
        char path[300];
        snprintf(path, sizeof path, "%s/%s", sock_dir(), e->d_name);
        char *info = request(path, F_QUERY);
        if (info) printf("%s\n", info);
        else printf("%.*s\t(stale socket)\n", (int)(n - 5), e->d_name);
        free(info);
    }
    closedir(d);
    return 0;
}

/* ── connect (599) ───────────────────────────────────────────────────────────────────────── */

/* `deckhold connect -p PORT`: stdin/stdout ⇄ one TCP connection to this guest's loopback PORT
 * (127.0.0.1, else ::1) — how the host forwards a sign-in's localhost callback from the Mac into the
 * sandbox (the browser bridge), as a plain exec: no network interface, no listener in the guest.
 * stdin's end half-closes the socket (the request is complete); the socket's end ends the command.
 * Exit 3 when nothing listens there. */
static int connect_port(int port) {
    int fd = -1;
    struct sockaddr_in a4 = { .sin_family = AF_INET, .sin_port = htons((uint16_t)port), .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
    fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd >= 0 && connect(fd, (struct sockaddr *)&a4, sizeof a4) != 0) { close(fd); fd = -1; }
    if (fd < 0) {
        struct sockaddr_in6 a6 = { .sin6_family = AF_INET6, .sin6_port = htons((uint16_t)port), .sin6_addr = IN6ADDR_LOOPBACK_INIT };
        fd = socket(AF_INET6, SOCK_STREAM, 0);
        if (fd >= 0 && connect(fd, (struct sockaddr *)&a6, sizeof a6) != 0) { close(fd); fd = -1; }
    }
    if (fd < 0) { fprintf(stderr, "deckhold: connect: nothing listens on localhost:%d\n", port); return 3; }
    signal(SIGPIPE, SIG_IGN);
    bool in_open = true;
    uint8_t b[16384];
    for (;;) {
        struct pollfd p[2] = { { .fd = fd, .events = POLLIN }, { .fd = in_open ? 0 : -1, .events = POLLIN } };
        if (poll(p, 2, -1) < 0) { if (errno == EINTR) continue; break; }
        if (p[0].revents & (POLLIN | POLLHUP | POLLERR)) {
            ssize_t n = read(fd, b, sizeof b);
            if (n <= 0) break;
            if (!write_all(1, b, (size_t)n)) break;
        }
        if (in_open && (p[1].revents & (POLLIN | POLLHUP | POLLERR))) {
            ssize_t n = read(0, b, sizeof b);
            if (n <= 0) { in_open = false; shutdown(fd, SHUT_WR); }
            else if (!write_all(fd, b, (size_t)n)) break;
        }
    }
    close(fd);
    return 0;
}

/* ── main ───────────────────────────────────────────────────────────────────────────────── */

static int usage(void) {
    fprintf(stderr,
            "usage: deckhold serve -s NAME [-x COLS -y ROWS] [--scrollback BYTES] [-f] -- CMD [ARGS...]\n"
            "       deckhold attach -s NAME\n"
            "       deckhold pipe -s NAME       relay stdio ⇄ the session socket verbatim (host transport)\n"
            "       deckhold ls                 sessions: name, pid, size, clients, screen, history rows, the\n"
            "                                   program's status (OSC 7501); ended ones as NAME<TAB>ended=CODE\n"
            "       deckhold dump -s NAME       the holder's active screen as plain text + cursor\n"
            "       deckhold exec -- CMD [ARGS...]   reset every signal to default, then exec CMD\n"
            "       deckhold connect -p PORT    stdio ⇄ TCP localhost:PORT in this guest (the browser bridge)\n"
            "sockets live in $DECKHOLD_DIR (default /run/deckhold)\n");
    return 2;
}

/* Give the program the signal state a login would: every disposition default, nothing blocked.
 * Needed because whatever launched the holder may have left signals ignored — measured here:
 * BusyBox ash (Alpine's /bin/sh) sets SIGQUIT to ignored and leaks that into the command it execs
 * (vminitd itself does not: the container's PID 1 has SigIgn 0). POSIX shells cannot trap or reset
 * a signal that was ignored on entry, so a script's `trap … QUIT` silently does nothing — the
 * a terminal screensaver's `m` menu (stty quit m → SIGQUIT) is exactly that. A PTY holder is the
 * process that "logs the program in", so a clean signal state is its job. */
static void reset_signals(void) {
    for (int sig = 1; sig < NSIG; sig++)
        if (sig != SIGKILL && sig != SIGSTOP) signal(sig, SIG_DFL);
    sigset_t none;
    sigemptyset(&none);
    sigprocmask(SIG_SETMASK, &none, NULL);
}

int main(int argc, char **argv) {
    if (argc < 2) return usage();
    const char *cmd = argv[1];
    const char *name = NULL;
    unsigned cols = 80, rows = 24;
    size_t scrollback = 10u << 20;       /* BYTES — ~9,000 rows at 120 columns */
    bool fg = false;
    int port = 0;
    int i = 2;
    for (; i < argc; i++) {
        if (!strcmp(argv[i], "--")) { i++; break; }
        if (!strcmp(argv[i], "-s") && i + 1 < argc) name = argv[++i];
        else if (!strcmp(argv[i], "-p") && i + 1 < argc) port = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-x") && i + 1 < argc) cols = (unsigned)atoi(argv[++i]);
        else if (!strcmp(argv[i], "-y") && i + 1 < argc) rows = (unsigned)atoi(argv[++i]);
        else if (!strcmp(argv[i], "--scrollback") && i + 1 < argc) scrollback = (size_t)strtoull(argv[++i], NULL, 10);
        else if (!strcmp(argv[i], "-f")) fg = true;
        else return usage();
    }
    if (!strcmp(cmd, "ls")) return ls();
    if (!strcmp(cmd, "connect")) return port >= 1 && port <= 65535 ? connect_port(port) : usage();
    if (!strcmp(cmd, "exec")) {            /* deckhold exec -- CMD…: reset signals, then exec (used to start tmux) */
        if (i >= argc) return usage();
        reset_signals();
        execvp(argv[i], argv + i);
        fprintf(stderr, "deckhold: exec %s: %s\n", argv[i], strerror(errno));
        return 127;
    }
    if (!name) return usage();
    if (!strcmp(cmd, "attach")) return attach(name);
    if (!strcmp(cmd, "pipe")) return pipe_mode(name);
    if (!strcmp(cmd, "dump")) return dump(name);
    if (!strcmp(cmd, "serve")) {
        if (i >= argc || !cols || !rows || cols > 1000 || rows > 1000) return usage();
        return serve(argc - i, argv + i, name, (uint16_t)cols, (uint16_t)rows, scrollback, fg);
    }
    return usage();
}
