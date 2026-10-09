/*
 * status-check.c — deckhold's OSC 7501 (program status) consumer: the query is answered, reports are kept by
 * the spec's rules and limits, invalid input is discarded, and none of it depends on where a read cut the
 * bytes. deckhold's own code (`#include "../deckhold.c"`), built for the Mac by run.sh beside snapshot-check.
 *
 * Exit 0 = every check passed. Usage: status-check [fuzz-iterations] [seed]
 */
#define main deckhold_main
#include "../deckhold.c"
#undef main

static int failures, checks;

static void check(bool ok, const char *what) {
    checks++;
    if (!ok) { failures++; printf("FAIL %s\n", what); }
}

static void reset(void) {
    memset(&PS, 0, sizeof PS);
    buf_free(&S.master_out);
    for (int i = 0; i < S.nclients; i++) buf_free(&S.c[i].out);
    S.nclients = 0;
}

static void feed(const char *s) { ps_scan((const uint8_t *)s, strlen(s)); }
static void feedn(const char *s, size_t n) { ps_scan((const uint8_t *)s, n); }

/* The root record as its INFO fields, without the age (a fresh string; "" when there is none). */
static char *root_text(void) {
    struct buf b = {0};
    ps_fields(&b, false);
    buf_add(&b, "", 1);
    char *s = strdup((char *)b.p);
    buf_free(&b);
    char *age = strstr(s, "\tstatus_age=");
    if (age) *age = 0;
    return s;
}

static bool root_is(const char *want) {
    char *got = root_text();
    bool ok = strcmp(got, want) == 0;
    if (!ok) printf("     root: got [%s] want [%s]\n", got, want);
    free(got);
    return ok;
}

static int records(void) {
    int n = 0;
    for (int i = 0; i < PS_MAX_RECORDS; i++) n += PS.r[i].used;
    return n;
}

static int answers(void) {
    int n = 0;
    const char *a = "\x1b]7501;?\x1b\\";
    size_t al = strlen(a);
    for (size_t i = 0; i + al <= S.master_out.len; i++)
        if (!memcmp(S.master_out.p + i, a, al)) n++;
    return S.master_out.len == (size_t)n * al ? n : -1;   /* nothing else was written */
}

/* Feed `s` cut at every offset (two reads), and byte by byte: `test` must hold after each. */
static void every_cut(const char *s, bool (*test)(void), const char *what) {
    size_t n = strlen(s);
    char label[256];
    for (size_t cut = 0; cut <= n; cut++) {
        reset();
        feedn(s, cut);
        feedn(s + cut, n - cut);
        snprintf(label, sizeof label, "%s (cut at %zu)", what, cut);
        check(test(), label);
    }
    reset();
    for (size_t i = 0; i < n; i++) feedn(s + i, 1);
    snprintf(label, sizeof label, "%s (byte by byte)", what);
    check(test(), label);
}

static bool one_answer(void) { return answers() == 1 && records() == 0; }
static bool working_claude(void) { return root_is("status=state=working:app=claude-code:msg=aGVsbG8=") && answers() == 0; }
static bool blocked_perm(void) { return root_is("status=state=blocked:app=pi:kind=permission:progress=40") && records() == 1; }

static char *b64(const char *t) {
    static const char a[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    size_t n = strlen(t);
    char *o = malloc(n / 3 * 4 + 8), *p = o;
    for (size_t i = 0; i < n; i += 3) {
        uint32_t v = (uint32_t)(uint8_t)t[i] << 16 | (i + 1 < n ? (uint32_t)(uint8_t)t[i + 1] << 8 : 0) | (i + 2 < n ? (uint8_t)t[i + 2] : 0);
        *p++ = a[v >> 18 & 63]; *p++ = a[v >> 12 & 63];
        *p++ = i + 1 < n ? a[v >> 6 & 63] : '=';
        *p++ = i + 2 < n ? a[v & 63] : '=';
    }
    *p = 0;
    return o;
}

static void report(const char *body) {
    struct buf b = {0};
    buf_str(&b, "\x1b]7501;");
    buf_str(&b, body);
    buf_str(&b, "\x1b\\");
    feedn((char *)b.p, b.len);
    buf_free(&b);
}

/* A report whose `msg` decodes to `len` bytes of 'x'. */
static void report_msg_len(size_t len) {
    char *t = malloc(len + 1);
    memset(t, 'x', len);
    t[len] = 0;
    char *e = b64(t);
    char *body = malloc(strlen(e) + 32);
    sprintf(body, "state=working:msg=%s", e);
    report(body);
    free(t); free(e); free(body);
}

static size_t frames_of(struct buf *b, uint8_t type) {
    size_t n = 0;
    for (size_t at = 0; at + 5 <= b->len; at += 5 + be32(b->p + at + 1)) n += b->p[at] == type;
    return n;
}

int main(int argc, char **argv) {
    int iterations = argc > 1 ? atoi(argv[1]) : 20000;
    unsigned seed = argc > 2 ? (unsigned)strtoul(argv[2], NULL, 10) : 612;

    /* The query: answered once, ST or BEL, wherever the read is cut. */
    every_cut("\x1b]7501;?\x1b\\", one_answer, "query (ESC \\) is answered once");
    every_cut("abc\x1b]7501;?\x07xyz", one_answer, "query (BEL) is answered once");
    reset(); feed("\x1b]7501;?\x1b\\\x1b]7501;?\x07"); check(answers() == 2, "two queries, two answers");
    reset(); for (int i = 0; i < 40; i++) feed("\x1b]7501;?\x07");
    check(answers() == PS_ANSWERS_PER_SECOND, "a flood of queries (an echoed answer): at most 16 answers a second");
    reset(); feed("\x1b]7502;?\x1b\\\x1b]750;?\x1b\\\x1b]17501;?\x07"); check(answers() == 0, "other OSC numbers are not ours");

    /* Reports, cut anywhere. */
    every_cut("\x1b[1m\x1b]7501;state=working:app=claude-code:msg=aGVsbG8\x1b\\\x1b[0m", working_claude, "a root report (unpadded base64)");
    every_cut("\x1b]7501; state = blocked : app=pi :kind=permission:progress=40\x07", blocked_perm, "whitespace around keys and values");

    /* A report replaces its record: keys left out are gone. */
    reset();
    report("state=working:app=a:msg=aGk=");
    report("state=done");
    check(root_is("status=state=done"), "a report replaces the record whole");

    /* Validation. */
    reset(); report("state=working:garbage:x:=1:app=ok"); check(root_is("status=state=working:app=ok"), "a malformed pair is skipped, the rest kept");
    reset(); report("state=working:APP=x"); check(root_is("status=state=working"), "a key outside [a-z] is skipped");
    reset(); report("state=working:app=a;b"); check(root_is("status=state=working"), "a value byte outside the set skips the pair");
    reset(); report("state=sleeping"); check(records() == 0, "an unknown state: ignored");
    reset(); report("app=x"); check(records() == 0, "no state: ignored");
    reset(); report("state=working:state=done"); check(root_is("status=state=done"), "a duplicate key: the last wins");
    reset(); report("state=working:color=red"); check(root_is("status=state=working"), "an unknown key is ignored");
    reset(); report("state=blocked:kind=coffee"); check(root_is("status=state=blocked"), "an unknown kind: absent");
    reset(); report("state=working:kind=permission"); check(root_is("status=state=working"), "kind applies to blocked only");
    reset(); report("state=working:progress=101"); check(root_is("status=state=working"), "progress over 100: absent");
    reset(); report("state=working:progress=4x"); check(root_is("status=state=working"), "progress not an integer: absent");
    reset(); report("state=done:progress=50"); check(root_is("status=state=done"), "progress applies to working/blocked only");
    reset(); report("state=working:app=bad,name"); check(root_is("status=state=working"), "an app outside its set: absent");
    reset(); report("state=working:app=abcdefghijklmnopqrstuvwxyz0123456"); check(records() == 0, "an app over 32 bytes: discarded whole");
    reset(); report("state=working:abcdefghijklmnopq=1"); check(records() == 0, "a key over 16 bytes: discarded whole");
    reset(); report("state=working:msg=@@@"); check(root_is("status=state=working"), "msg with a byte outside the value set: the pair is skipped");
    reset(); report("state=working:msg=aGVsbG8gd2=y"); check(records() == 0, "bad base64: discarded whole");
    reset(); report("state=working:msg=YQ"); check(root_is("status=state=working:msg=YQ=="), "base64 padding is optional (stored padded)");
    { char *e = b64("a\nb"), body[64]; snprintf(body, sizeof body, "state=working:msg=%s", e); reset(); report(body); free(e);
      check(records() == 0, "a control character in msg: discarded whole"); }
    { char *e = b64("a\xc2\x85" "b"), body[64]; snprintf(body, sizeof body, "state=working:title=%s", e); reset(); report(body); free(e);
      check(records() == 0, "a C1 control in title: discarded whole"); }
    { char *e = b64("caf\xc3\xa9 \xe2\x9c\x93"), body[64], want[96]; snprintf(body, sizeof body, "state=done:msg=%s", e);
      snprintf(want, sizeof want, "status=state=done:msg=%s", e); reset(); report(body); free(e);
      check(root_is(want), "UTF-8 text is kept"); }
    reset(); report_msg_len(2048); check(records() == 1, "msg of 2048 bytes: kept");
    reset(); report_msg_len(2049); check(records() == 0, "msg over 2048 bytes: discarded whole");
    { /* encoded over 2732 bytes, though it would decode short enough: checked before decoding */
      struct buf b = {0}; buf_str(&b, "state=working:msg=");
      for (int i = 0; i < 2733; i++) buf_str(&b, "=");
      buf_add(&b, "", 1); reset(); report((char *)b.p); buf_free(&b);
      check(records() == 0, "msg encoded over 2732 bytes: discarded whole"); }
    { char t[194]; memset(t, 'y', 193); t[193] = 0; char *e = b64(t), body[400]; snprintf(body, sizeof body, "state=working:title=%s", e);
      reset(); report(body); free(e); check(records() == 0, "title over 192 bytes: discarded whole"); }
    { /* a sequence over 4096 bytes: discarded whole, and the next one still works */
      struct buf b = {0}; buf_str(&b, "state=working:pad=");
      for (int i = 0; i < 4100; i++) buf_str(&b, "a");
      buf_add(&b, "", 1); reset(); report((char *)b.p); buf_free(&b);
      check(records() == 0, "a sequence over 4096 bytes: discarded whole");
      report("state=idle"); check(root_is("status=state=idle"), "... and the scanner is back in step"); }

    /* ids */
    reset(); report("state=working:id=build/test"); check(records() == 1 && root_is(""), "a child record is not the root");
    reset(); report("state=working:id=a/b/c/d/e/f/g/h"); check(records() == 1, "8 levels: kept");
    reset(); report("state=working:id=a/b/c/d/e/f/g/h/i"); check(records() == 0, "9 levels: discarded");
    reset(); report("state=working:id=a//b"); check(records() == 0, "an empty segment: discarded (never the root)");
    reset(); report("state=working:id=a/"); check(records() == 0, "a trailing slash: discarded");
    reset(); report("state=working:id=abcdefghijklmnopqrstuvwxyz0123456"); check(records() == 0, "a 33-byte segment: discarded");
    reset(); report("state=working:id="); check(records() == 0, "an empty id: discarded (never the root)");
    reset();
    report("state=working"); report("state=working:id=build"); report("state=blocked:id=build/test"); report("state=done:id=builder");
    report("state=clear:id=build");
    check(records() == 2 && root_is("status=state=working"), "clear id=X removes X and below, not a sibling with the same prefix");
    report("state=clear"); check(records() == 0, "clear with no id removes every record");
    reset(); report("state=working:id=x"); report("state=working:id=x"); check(records() == 1, "the same id replaces, never duplicates");

    /* 256 records: the least recently updated goes. */
    reset();
    report("state=working:app=root");
    for (int i = 0; i < 255; i++) { char b[64]; snprintf(b, sizeof b, "state=working:id=t%d", i); report(b); }
    check(records() == 256, "256 records are kept");
    report("state=working:id=one-more");
    check(records() == 256 && root_is(""), "the 257th drops the least recently updated (the root, here)");
    report("state=idle:id=t0"); report("state=idle:id=another");
    bool t0 = false;
    for (int i = 0; i < PS_MAX_RECORDS; i++) t0 |= PS.r[i].used && !strcmp(PS.r[i].id, "t0");
    check(t0, "a record updated recently is not the one dropped");

    /* RIS, CAN/SUB, other sequences around it. */
    reset(); report("state=done"); feed("\x1b" "c"); check(records() == 0, "a full reset (RIS) removes every record");
    reset(); report("state=done"); feed("\x1b[2J\x1b[!p"); check(records() == 1, "a clear screen or a soft reset keeps them");
    reset(); feed("\x1b]7501;state=working\x18" "abc\x1b]7501;state=done\x1a\x07"); check(records() == 0, "CAN / SUB cancel a sequence");
    reset(); feed("\x1b]52;c;7501;state=working\x07\x1b]0;7501;state=error\x1b\\"); check(records() == 0, "another OSC's text is never a report");
    reset(); feed("\x1b]7501;state=working\x1b[0m"); check(records() == 0, "an OSC cut off by another sequence is dropped");
    feed("\x1b]7501;state=done\x07"); check(root_is("status=state=done"), "... and the next one is read");
    reset(); feed("\x1bP7501;state=working\x1b\\"); check(records() == 0, "a DCS is not an OSC");

    /* Watchers: one STATUS frame per change of the ROOT, none for a child; INFO carries the fields. */
    reset();
    S.nclients = 2;
    S.c[0] = (struct client){ .fd = -1, .watch = true };
    S.c[1] = (struct client){ .fd = -1, .hello = true };
    report("state=working");
    report("state=blocked:id=sub");
    report("state=clear:id=sub");
    report("state=done:msg=aGk=");
    check(frames_of(&S.c[0].out, F_STATUS) == 2, "a watcher gets a STATUS frame for each root change only");
    check(frames_of(&S.c[1].out, F_STATUS) == 0, "a viewer never gets STATUS frames");
    report("state=clear");
    check(frames_of(&S.c[0].out, F_STATUS) == 3, "clearing the root is told");
    { size_t at = 0, last = 0;
      for (; at + 5 <= S.c[0].out.len; at += 5 + be32(S.c[0].out.p + at + 1)) last = at;
      check(be32(S.c[0].out.p + last + 1) == 0, "an empty STATUS frame = no record"); }
    reset();
    S.term = NULL;
    { GhosttyTerminalOptions to = { .cols = 80, .rows = 24, .max_scrollback = 1 << 20 };
      if (ghostty_terminal_new(NULL, &S.term, to) != GHOSTTY_SUCCESS) { printf("FAIL ghostty_terminal_new\n"); return 2; } }
    S.name = "main"; S.cols = 80; S.rows = 24;
    snprintf(S.cmdline, sizeof S.cmdline, "claude --x");
    report("state=blocked:app=claude-code:kind=question:title=VGl0bGU=");
    { struct buf b = {0}; info_line(&b); buf_add(&b, "", 1);
      const char *line = (char *)b.p + 5;
      check(strstr(line, "\tstatus=state=blocked:app=claude-code:kind=question:title=VGl0bGU=\tstatus_age=0\tclaude --x") != NULL,
            "INFO carries the status before the command");
      if (!strstr(line, "\tstatus=")) printf("     INFO: %s\n", line);
      buf_free(&b); }
    reset();
    { struct buf b = {0}; info_line(&b); buf_add(&b, "", 1);
      check(strstr((char *)b.p + 5, "status") == NULL && strstr((char *)b.p + 5, "\tclaude --x"), "no record: INFO as before");
      buf_free(&b); }

    /* Fuzz: random runs of reports, queries, other sequences and noise; feeding them in random cuts ends in
     * exactly the state (records, answers) that feeding them whole does. Nothing crashes on garbage. */
    static const char *const parts[] = {
        "\x1b]7501;?\x1b\\", "\x1b]7501;?\x07", "\x1b]7501;state=working:app=claude-code\x1b\\", "\x1b]7501;state=done:msg=ZG9uZQ==\x07",
        "\x1b]7501;state=blocked:kind=permission:id=a/b\x1b\\", "\x1b]7501;state=clear:id=a\x07", "\x1b]7501;state=clear\x1b\\",
        "\x1b]7501;state=error:msg=!!\x07", "\x1b]7501;state=bogus\x07", "\x1b]0;title\x07", "\x1b]52;c;aGk=\x1b\\", "\x1b[31m",
        ("\x1b" "c"), "hello world\r\n", "\x1b", "\x1b]", "\x1b]75", "\x07", "\x18", "\xe2\x9c\x93", "\x1b\\", ";:=",
    };
    const int nparts = sizeof parts / sizeof parts[0];
    srand(seed);
    int mismatches = 0;
    for (int it = 0; it < iterations; it++) {
        struct buf in = {0};
        int k = 1 + rand() % 24;
        for (int j = 0; j < k; j++) {
            if (rand() % 6 == 0) { uint8_t g = (uint8_t)rand(); buf_add(&in, &g, 1); }
            else buf_str(&in, parts[rand() % nparts]);
        }
        reset();
        ps_scan(in.p, in.len);
        char *whole = root_text();
        int whole_records = records(), whole_answers = (int)S.master_out.len;
        reset();
        for (size_t at = 0; at < in.len;) {
            size_t step = 1 + (size_t)rand() % 9;
            if (at + step > in.len) step = in.len - at;
            ps_scan(in.p + at, step);
            at += step;
        }
        char *cut = root_text();
        if (strcmp(whole, cut) || whole_records != records() || whole_answers != (int)S.master_out.len) mismatches++;
        free(whole); free(cut);
        buf_free(&in);
    }
    char label[96];
    snprintf(label, sizeof label, "fuzz: %d inputs, the same state however the reads are cut", iterations);
    check(mismatches == 0, label);
    if (mismatches) printf("     %d mismatches (seed %u)\n", mismatches, seed);

    printf("%s: %d checks, %d failed\n", failures ? "status-check FAILED" : "status-check ok", checks, failures);
    return failures ? 1 : 0;
}
