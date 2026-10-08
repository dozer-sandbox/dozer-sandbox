/*
 * dozview — the guest half of workspace rules (.dozignore / .dozreadonly): a filtering view of a
 * virtio-fs share, served at the share's guest path (e.g. /workspace) over the RAW /dev/fuse protocol.
 * No libfuse (LGPL-2.1: static linking would oblige us to ship relinkable objects); libc, pthreads and
 * the Linux UAPI headers only. MIT (this package).
 *
 * NOT A SECURITY BOUNDARY. Root in the guest (the agent has sudo by default) can stop the view, read
 * through its directory descriptor (/proc/PID/fd/N/...), or reach the raw share. The view keeps an agent
 * from stumbling into files; the VM is the boundary.
 *
 *   dozview start --raw RAW --mount MNT --conf CONF --state STATE --pidfile PID --log LOG
 *                 [--threads N] [--timeout S]
 *   dozview version
 *
 * RAW is the share bound privately (production: /run/doz/raw/<tag>, under a 0700 /run/doz/raw); MNT is
 * an EMPTY directory (the share's guest path). `start` opens /dev/fuse, mounts the view
 * (allow_other,default_permissions), forks the SUPERVISOR (own session, stdio /dev/null), prints its pid
 * and exits 0 — so a privileged exec that runs it ends at once and the view outlives it.
 *
 * CONF (written by the host, re-read on SIGHUP/SIGUSR1):  mode=lock|hide   fold=0|1
 *   mode  what .dozignore does. lock: the name is listed with mode 000 and every open/read/list/
 *         write/rename/unlink/setattr is EACCES for every uid, root too (the view refuses, not the
 *         kernel's permission check). hide: lookup is ENOENT and the name is not listed.
 *   fold  the share's Mac volume is case-insensitive: ALSO evaluate the folded rules against the folded
 *         path (dozmatch.h) — `cat SECRET.ENV` must not read a locked secret.env. Only ever hides more.
 * RULES, read from RAW's root: .dozignore (Docker's .dockerignore syntax and BuildKit's walker semantics
 *   — dozmatch.c) and .dozreadonly (same syntax: visible, readable, write bits not shown, every
 *   mutation EROFS for root; the kernel gives a non-root user EACCES for a write first, because the
 *   write bits are not shown). Implicitly read-only, before the user's .dozreadonly lines (so `!name`
 *   there re-allows them): doz_project.yaml, doz_project.yml, .git/hooks. ALWAYS visible and read-only
 *   whatever the rules say: .dozignore and .dozreadonly themselves (an agent must not edit its own rules).
 *   A rule file's change is picked up within ~250 ms (mtime/size/inode poll) or at once on SIGHUP, and
 *   the kernel's cached entries/attributes are invalidated (FUSE_NOTIFY_INVAL_ENTRY / _INODE).
 *   A directory that an exception could re-include from is shown (a "skeleton") holding only what is
 *   re-included — the walker rule (fsutil's SkipDir) decides, as for `docker build`.
 *   A line that does not parse is dropped and logged (doz reports it on the Mac), never fatal.
 *
 * Signals (to the SUPERVISOR, whose pid is in PID; it forwards them to the current worker):
 *   SIGUSR1  re-open the base directory from RAW's PATH (the wake re-binds RAW, then signals in the same
 *            script) and re-read the conf and the rules.
 *   SIGHUP   re-read the conf and the rules.          SIGTERM  unmount (lazy) and exit.
 *
 * The three guards the lifecycle spike found (workspace the 599g lifecycle spike, 599g.03-SPIKE.md):
 *   1. After a hibernation the base fd is DEAD (its dentry carries a node id the new virtio-fs server
 *      does not know) and fstat() on it still succeeds. Health = opening "." through it AND the
 *      virtio-fs magic. Rules are never re-read through an unhealthy base: the last rules are kept.
 *   2. Self-repair is a BACKUP to SIGUSR1: a request whose syscall fails ENOENT/ESTALE/EIO checks the
 *      base (at most every 50 ms), re-opens it when dead and retries once; the watcher also tries every
 *      250 ms.
 *   3. A re-open never adopts anything that is not the virtio-fs share (statfs magic): between the
 *      wake's `umount -l RAW` and its bind the path is the EMPTY tmpfs folder underneath.
 *   An open file whose descriptor died in a hibernation is re-opened by its path and the read/write
 *   retried once (raw virtio-fs fails it; the view heals it).
 *
 * Supervision (instead of deckhold: deckhold is a PTY holder whose life is the sessions'; coupling the
 * view to it would tie two unrelated guest helpers together, and a 60-line loop in this binary is
 * enough). The supervisor holds the /dev/fuse descriptor; the WORKER (a forked child) serves it. When
 * the worker dies (a crash, or root killing it), the connection stays up (the supervisor still holds
 * it) and a new worker serves on within ~100 ms (back-off up to 5 s on a crash loop). Node ids and file
 * handles carry the worker generation in their top bits, so a new worker answers ESTALE / EBADF for a
 * dead worker's ids instead of confusing them with its own; the kernel re-looks entries up from the
 * root (nodeid 1, always valid), so /workspace and every path walked from it keep working — a process
 * whose cwd is a SUBfolder may need to `cd` again, and a request in flight at the moment of the crash
 * is lost (its caller waits until killed). If the connection itself goes (someone unmounted MNT), the
 * supervisor mounts a fresh view. If the supervisor is gone, the host's wake script starts a new one.
 *
 * Threads: N (default 6) request threads read /dev/fuse concurrently (the kernel hands each read one
 * request); syscalls run outside the one mutex, which guards the node table, the rules and the handle
 * tables. One watcher thread per worker handles signals and polls the rule files.
 *
 * Build: Guest/dozview/build.sh (the pinned Zig, static aarch64-linux-musl); provenance in PROVENANCE.md.
 */
#define _GNU_SOURCE
#include <stddef.h>
#include <linux/fuse.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <fnmatch.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/fsuid.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/syscall.h>
#include <sys/uio.h>
#include <sys/vfs.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "dozmatch.h"

#ifndef RENAME_EXCHANGE
#define RENAME_EXCHANGE (1 << 1)
#endif

#define DOZVIEW_VERSION "1.1.1"
#define VIRTIOFS_MAGIC 0x65735546UL /* FUSE_SUPER_MAGIC — virtio-fs is a FUSE file system */
#define PATHMAX 4096
#define BUFSZ ((size_t)(1 << 20) + 8192)
#define MAX_PAGES 256 /* 1 MiB per READ/WRITE */

/* ------------------------------------------------------------------ configuration */
static const char *raw_path, *mnt_path, *conf_path, *state_path, *pid_path, *log_path;
/* The inode of the folder the view is mounted in: the ".." the root lists (read at start, outside the mount). */
static uint64_t mnt_parent_ino = 1;
static int nthreads = 6;
static double tmo = 1.0;
static int fusefd = -1;          /* the connection (inherited by the worker) */
static int basefd = -1;          /* the raw share's root (replaced in place with dup3) */
static uint64_t wgen = 1;        /* this worker's generation (top 16 bits of node ids / handles) */
static int restarts;             /* how many workers came before this one */

/* ------------------------------------------------------------------ log */
static pthread_mutex_t log_mu = PTHREAD_MUTEX_INITIALIZER;
static FILE *logf_;
static void logm(const char *fmt, ...) {
    pthread_mutex_lock(&log_mu);
    if (!logf_ && log_path) logf_ = fopen(log_path, "a");
    if (logf_) {
        if (ftell(logf_) > 1024 * 1024) { /* bounded: tmpfs is RAM */
            fclose(logf_);
            char old[PATHMAX]; snprintf(old, sizeof old, "%s.1", log_path);
            rename(log_path, old);
            logf_ = fopen(log_path, "a");
        }
    }
    if (logf_) {
        struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts);
        fprintf(logf_, "%ld.%03ld [%d] ", (long)ts.tv_sec, ts.tv_nsec / 1000000, (int)getpid());
        va_list ap; va_start(ap, fmt); vfprintf(logf_, fmt, ap); va_end(ap);
        fputc('\n', logf_); fflush(logf_);
    }
    pthread_mutex_unlock(&log_mu);
}

static double now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e3 + t.tv_nsec / 1e6; }

/* ------------------------------------------------------------------ the one mutex */
static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;

/* ------------------------------------------------------------------ rules */
enum { C_NONE = 0, C_RO = 1, C_EXCL = 2 };
static const char *implicit_ro[] = {"doz_project.yaml", "doz_project.yml", ".git/hooks"};
#define N_IMPLICIT 3

typedef struct {
    dm_set ign[2], ro[2];     /* [0] exact, [1] folded (only when fold) */
    int fold, hide;
    int n_ign, n_ro, n_bad;   /* the user's patterns (ro: without the implicit ones), lines dropped */
    int ign_present, ro_present;
    uint64_t gen;
} rules_t;
static rules_t *R;            /* current rules; swapped under mu */
static uint64_t rules_gen_counter = 1;
static uint64_t struct_gen = 1; /* bumped when a DIRECTORY is renamed (its subtree's paths change) */

typedef struct { int present; dev_t dev; ino_t ino; off_t size; struct timespec mt; } fileid_t;
static fileid_t fid_ign, fid_ro, fid_conf;

static void bad_cb(void *ctx, int i, const char *p, const char *why) {
    int *n = ctx; (*n)++;
    logm("rules: dropped a pattern that does not parse: '%s' (%s)", p, why ? why : "bad pattern");
}

/* Read one rule file through the base: its patterns (parsed), or none. Returns -1 when the read failed
 * for a reason other than "not there" (the caller then keeps the last rules). */
static int read_rules(const char *name, char ***pats, int **lines, int *n, fileid_t *fid) {
    *pats = NULL; *lines = NULL; *n = 0; memset(fid, 0, sizeof *fid);
    int fd = openat(basefd, name, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return (errno == ENOENT || errno == ENOTDIR || errno == ELOOP) ? 0 : -1;
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) { close(fd); return 0; }
    if (st.st_size > 1024 * 1024) { logm("rules: %s is over 1 MiB — ignored", name); close(fd); return 0; }
    char *buf = malloc((size_t)st.st_size + 1); size_t len = 0;
    if (!buf) { close(fd); return -1; }
    for (;;) {
        ssize_t r = read(fd, buf + len, (size_t)st.st_size + 1 - len);
        if (r < 0) { if (errno == EINTR) continue; free(buf); close(fd); return -1; }
        if (r == 0 || len + (size_t)r > (size_t)st.st_size) { len += (size_t)(r > 0 ? r : 0); break; }
        len += (size_t)r;
    }
    close(fd);
    if (len > (size_t)st.st_size) len = (size_t)st.st_size;
    *n = dm_parse_file(buf, len, pats, lines);
    free(buf);
    if (*n < 0) { *n = 0; return -1; }
    fid->present = 1; fid->dev = st.st_dev; fid->ino = st.st_ino; fid->size = st.st_size; fid->mt = st.st_mtim;
    return 0;
}

static void conf_read(int *hide, int *fold) {
    *hide = 0; *fold = 0;
    memset(&fid_conf, 0, sizeof fid_conf);
    FILE *f = conf_path ? fopen(conf_path, "re") : NULL;
    if (!f) return;
    struct stat st;
    if (fstat(fileno(f), &st) == 0) { fid_conf.present = 1; fid_conf.ino = st.st_ino; fid_conf.size = st.st_size; fid_conf.mt = st.st_mtim; }
    char line[256];
    while (fgets(line, sizeof line, f)) {
        if (!strncmp(line, "mode=hide", 9)) *hide = 1;
        else if (!strncmp(line, "fold=1", 6)) *fold = 1;
    }
    fclose(f);
}

static int build_set(dm_set *s, char **pats, int n, const char *const *prefix, int nprefix, int fold, int *nbad) {
    int total = n + nprefix;
    char **v = calloc((size_t)(total ? total : 1), sizeof *v);
    if (!v) return -1;
    for (int i = 0; i < nprefix; i++) v[i] = fold ? dm_fold_pattern(prefix[i]) : strdup(prefix[i]);
    for (int i = 0; i < n; i++) v[nprefix + i] = fold ? dm_fold_pattern(pats[i]) : strdup(pats[i]);
    int bad = 0;
    int r = dm_set_init(s, (const char *const *)v, total, 1, NULL, bad_cb, &bad);
    if (r == 0) dm_set_compile_all(s, bad_cb, &bad);
    for (int i = 0; i < total; i++) free(v[i]);
    free(v);
    if (!fold) *nbad += bad; /* the folded set re-reports the same lines */
    return r;
}

static void rules_free(rules_t *r) {
    if (!r) return;
    for (int k = 0; k < 2; k++) { dm_set_free(&r->ign[k]); dm_set_free(&r->ro[k]); }
    free(r);
}

static int base_healthy(void);
static void write_state(void);

/* Build new rules from the files; NULL when the base is not healthy (keep the last ones). */
static rules_t *rules_build(void) {
    if (!base_healthy()) return NULL;
    char **ip, **rp; int *il, *rl, ni, nr; fileid_t fi, fr;
    if (read_rules(".dozignore", &ip, &il, &ni, &fi) < 0) return NULL;
    if (read_rules(".dozreadonly", &rp, &rl, &nr, &fr) < 0) { dm_free_lines(ip, il, ni); return NULL; }
    /* a read through a base that died DURING the read looks like "no file": check again */
    if (!base_healthy()) { dm_free_lines(ip, il, ni); dm_free_lines(rp, rl, nr); return NULL; }
    rules_t *r = calloc(1, sizeof *r);
    if (!r) { dm_free_lines(ip, il, ni); dm_free_lines(rp, rl, nr); return NULL; }
    conf_read(&r->hide, &r->fold);
    /* No rule file = a PASSTHROUGH view (the host serves every share through one, so a process whose cwd
     * is in the share survives a hibernation): nothing is excluded or read-only, not even the implicit
     * read-only names — `git init` must still make .git/hooks. The implicit names and the rule files'
     * own protection apply once a rule file exists. */
    int any = fi.present || fr.present;
    for (int k = 0; k < (r->fold ? 2 : 1); k++) {
        build_set(&r->ign[k], ip, ni, NULL, 0, k, &r->n_bad);
        build_set(&r->ro[k], rp, nr, any ? implicit_ro : NULL, any ? N_IMPLICIT : 0, k, &r->n_bad);
    }
    r->n_ign = ni; r->n_ro = nr; r->ign_present = fi.present; r->ro_present = fr.present;
    fid_ign = fi; fid_ro = fr;
    dm_free_lines(ip, il, ni); dm_free_lines(rp, rl, nr);
    return r;
}

/* ------------------------------------------------------------------ nodes */
typedef struct node {
    uint64_t id;
    struct node *parent;      /* NULL only for the root; kept while detached (for nkids) */
    char *name;               /* NULL when detached (unlinked / renamed over) */
    uint64_t nlookup;
    uint32_t nkids;           /* nodes whose parent is this one */
    uint32_t mode;            /* S_IFMT of the last stat */
    struct node *hid, *hname; /* hash chains */
    uint64_t rgen, sgen;      /* classification cache key */
    int cls;
    uint8_t *info;            /* the walker's per-pattern results for this node: ign0 ign1 ro0 ro1 */
    int info_len;
} node;

static node root_node;
static node **tid, **tname; static size_t hsize, hcount;
static uint64_t next_id = 2;

static uint64_t mkid(uint64_t serial) { return (wgen << 48) | serial; }
static size_t hash_id(uint64_t id) { id ^= id >> 33; id *= 0xff51afd7ed558ccdULL; id ^= id >> 33; return (size_t)id & (hsize - 1); }
static size_t hash_name(const node *p, const char *name) {
    uint64_t h = (uint64_t)(uintptr_t)p * 0x9e3779b97f4a7c15ULL;
    for (const unsigned char *s = (const unsigned char *)name; *s; s++) h = (h ^ *s) * 0x100000001b3ULL;
    return (size_t)(h ^ (h >> 29)) & (hsize - 1);
}
static void h_insert_id(node *n) { size_t b = hash_id(n->id); n->hid = tid[b]; tid[b] = n; }
static void h_insert_name(node *n) { size_t b = hash_name(n->parent, n->name); n->hname = tname[b]; tname[b] = n; }
static void h_remove_id(node *n) { node **pp = &tid[hash_id(n->id)]; while (*pp && *pp != n) pp = &(*pp)->hid; if (*pp) *pp = n->hid; n->hid = NULL; }
static void h_remove_name(node *n) {
    if (!n->name) return;
    node **pp = &tname[hash_name(n->parent, n->name)]; while (*pp && *pp != n) pp = &(*pp)->hname;
    if (*pp) *pp = n->hname;
    n->hname = NULL;
}
static void h_grow(void) {
    size_t old = hsize; node **oi = tid;
    node **on = tname;
    hsize = old ? old * 2 : 4096;
    tid = calloc(hsize, sizeof *tid); tname = calloc(hsize, sizeof *tname);
    if (!tid || !tname) { logm("out of memory growing the node table"); _exit(70); }
    for (size_t i = 0; i < old; i++) {
        for (node *n = oi[i], *nx; n; n = nx) { nx = n->hid; h_insert_id(n); }
        for (node *n = on[i], *nx; n; n = nx) { nx = n->hname; h_insert_name(n); }
    }
    free(oi); free(on);
}
static node *node_by_id(uint64_t id) {
    if (id == FUSE_ROOT_ID) return &root_node;
    if (!hsize) return NULL;
    for (node *n = tid[hash_id(id)]; n; n = n->hid) if (n->id == id) return n;
    return NULL;
}
static node *child_find(node *p, const char *name) {
    if (!hsize) return NULL;
    for (node *n = tname[hash_name(p, name)]; n; n = n->hname) if (n->parent == p && n->name && !strcmp(n->name, name)) return n;
    return NULL;
}
static node *child_get(node *p, const char *name, uint32_t mode) {
    node *n = child_find(p, name);
    if (n) { n->mode = mode; return n; }
    if (hcount + 1 > hsize) h_grow();
    n = calloc(1, sizeof *n);
    if (!n) return NULL;
    n->name = strdup(name);
    if (!n->name) { free(n); return NULL; }
    n->id = mkid(next_id++); n->parent = p; n->mode = mode;
    p->nkids++; hcount++;
    h_insert_id(n); h_insert_name(n);
    return n;
}
static void node_try_free(node *n) {
    while (n && n != &root_node && n->nlookup == 0 && n->nkids == 0) {
        node *p = n->parent;
        h_remove_id(n); h_remove_name(n);
        free(n->name); free(n->info); free(n);
        hcount--;
        if (p) p->nkids--;
        n = p;
    }
}
static void node_detach(node *n) { /* the name no longer leads here (unlinked, renamed over) */
    if (!n || !n->name) return;
    h_remove_name(n); free(n->name); n->name = NULL;
    node_try_free(n);
}
/* The node's path relative to the base ("" for the root); -ESTALE when detached, -ENAMETOOLONG. */
static int node_path(const node *n, char *out, size_t cap) {
    const node *chain[512]; int k = 0;
    for (const node *x = n; x && x != &root_node; x = x->parent) {
        if (!x->name) return -ESTALE;
        if (k == 512) return -ENAMETOOLONG;
        chain[k++] = x;
    }
    size_t len = 0; out[0] = 0;
    for (int i = k - 1; i >= 0; i--) {
        size_t l = strlen(chain[i]->name);
        if (len + l + 2 > cap) return -ENAMETOOLONG;
        if (len) out[len++] = '/';
        memcpy(out + len, chain[i]->name, l); len += l; out[len] = 0;
    }
    return 0;
}
static int join(char *out, size_t cap, const char *dir, const char *name) {
    if (!*name || strchr(name, '/') || !strcmp(name, ".") || !strcmp(name, "..")) return -EINVAL;
    int k = snprintf(out, cap, "%s%s%s", dir, *dir ? "/" : "", name);
    return (k < 0 || (size_t)k >= cap) ? -ENAMETOOLONG : 0;
}
static const char *at(const char *rel) { return *rel ? rel : "."; }

/* ------------------------------------------------------------------ classification (mu held) */
static int is_rule_file(const char *rel, int fold) {
    int (*cmp)(const char *, const char *) = fold ? strcasecmp : strcmp;
    return !cmp(rel, ".dozignore") || !cmp(rel, ".dozreadonly");
}
static int info_size(const rules_t *r) { return r->ign[0].n + r->ign[1].n + r->ro[0].n + r->ro[1].n; }

/* Classify `rel` (a child of `parent`, whose own info is `pinfo` — NULL at the top level) into `out`
 * (info_size bytes). */
static int classify_with(const char *rel, int isdir, const uint8_t *pinfo, uint8_t *out) {
    const rules_t *r = R;
    int nv = r->fold ? 2 : 1, excl = 0, skip = 0, ro = 0;
    char *folded = r->fold ? dm_fold(rel) : NULL;
    const uint8_t *pi = pinfo; uint8_t *o = out;
    dm_set *sets[4] = {(dm_set *)&r->ign[0], (dm_set *)&r->ign[1], (dm_set *)&r->ro[0], (dm_set *)&r->ro[1]};
    for (int k = 0; k < 4; k++) {
        dm_set *s = sets[k];
        int variant = k & 1;
        if (variant >= nv || s->n == 0) { if (s->n) memset(o, 0, (size_t)s->n); o += s->n; if (pi) pi += s->n; continue; }
        const char *p = variant ? (folded ? folded : rel) : rel;
        int m = dm_match_parent(s, p, pi, o, NULL);
        if (m == DM_YES) {
            if (k < 2) { excl = 1; if (isdir && !dm_may_reinclude_inside(s, p)) skip = 1; }
            else ro = 1;
        }
        o += s->n; if (pi) pi += s->n;
    }
    free(folded);
    if ((r->ign_present || r->ro_present) && is_rule_file(rel, r->fold)) return C_RO;
    if ((excl && !isdir) || skip) return C_EXCL;
    return ro ? C_RO : C_NONE;
}

static int classify_node(node *n, char *pathbuf);
/* The info of `p` for its children (NULL for the root); classifies p first. */
static const uint8_t *parent_info(node *p, int *pcls) {
    char buf[PATHMAX];
    *pcls = classify_node(p, buf);
    return p == &root_node ? NULL : p->info;
}
static int classify_node(node *n, char *pathbuf) {
    if (n == &root_node) { pathbuf[0] = 0; return C_NONE; }
    if (n->rgen == R->gen && n->sgen == struct_gen && n->info) return node_path(n, pathbuf, PATHMAX) < 0 ? C_EXCL : n->cls;
    int pcls; const uint8_t *pi = parent_info(n->parent, &pcls);
    if (node_path(n, pathbuf, PATHMAX) < 0) return C_EXCL;
    int sz = info_size(R);
    /* `!n->info` too: with no pattern at all (a passthrough view) sz is 0 == a new node's info_len */
    if (n->info_len != sz || !n->info) { free(n->info); n->info = calloc((size_t)(sz ? sz : 1), 1); n->info_len = sz; }
    if (!n->info) return C_EXCL;
    n->cls = pcls == C_EXCL ? C_EXCL : classify_with(pathbuf, S_ISDIR(n->mode), pi, n->info);
    n->rgen = R->gen; n->sgen = struct_gen;
    return n->cls;
}
/* Classify a name in `p` without making a node. */
static int classify_child(node *p, const char *rel, int isdir) {
    int pcls; const uint8_t *pi = parent_info(p, &pcls);
    if (pcls == C_EXCL) return C_EXCL;
    int sz = info_size(R);
    uint8_t stackbuf[512]; uint8_t *tmp = sz <= 512 ? stackbuf : malloc((size_t)sz);
    if (!tmp) return C_EXCL;
    int c = classify_with(rel, isdir, pi, tmp);
    if (tmp != stackbuf) free(tmp);
    return c;
}
static int excl_err(void) { return R->hide ? ENOENT : EACCES; }
static int may_mutate(int cls) { return cls == C_EXCL ? excl_err() : cls == C_RO ? EROFS : 0; }
static int may_create(int cls) { return cls == C_EXCL ? EACCES : cls == C_RO ? EROFS : 0; }
static int parent_allows_entries(int pcls) { return pcls == C_EXCL ? excl_err() : pcls == C_RO ? EROFS : 0; }

/* Renaming a directory changes the paths under it — and so what an ANCHORED pattern matches there
 * (`mv config cfg` must not unlock config/secrets). Refused when some pattern could match below `dir`
 * in an alignment where one of dir's own components is matched by a non-`**` segment (a pattern that
 * reaches below through `**` alone is location-independent). Conservative: a segment with a class or
 * an escape counts as matching. */
static int seg_could_match(const char *seg, const char *name, int fold) {
    if (strpbrk(seg, "[\\")) return 1;
    return fnmatch(seg, name, fold ? FNM_CASEFOLD : 0) == 0;
}
static int align(char **ps, int np, char **ds, int nd, int fold, int anchored) {
    if (nd == 0) return np > 0 && anchored;
    if (np == 0) return 0;
    if (!strcmp(ps[0], "**")) {
        for (int k = 0; k <= nd; k++) if (align(ps + 1, np - 1, ds + k, nd - k, fold, anchored)) return 1;
        return 0;
    }
    return seg_could_match(ps[0], ds[0], fold) && align(ps + 1, np - 1, ds + 1, nd - 1, fold, 1);
}
static int split_segs(char *s, char **out, int max) { int n = 0; for (char *t = strtok(s, "/"); t && n < max; t = strtok(NULL, "/")) out[n++] = t; return n; }
static int dir_rename_sensitive(const char *dir) {
    const rules_t *r = R;
    const dm_set *sets[2] = {&r->ign[0], &r->ro[0]};
    char db[PATHMAX]; snprintf(db, sizeof db, "%s", dir);
    char *ds[256]; int nd = split_segs(db, ds, 256);
    for (int k = 0; k < 2; k++)
        for (int i = 0; i < sets[k]->n; i++) {
            char pb[PATHMAX]; snprintf(pb, sizeof pb, "%s", dm_pattern_text(sets[k], i));
            char *ps[256]; int np = split_segs(pb, ps, 256);
            if (align(ps, np, ds, nd, r->fold, 0)) return 1;
        }
    return 0;
}

/* ------------------------------------------------------------------ the base */
static pthread_mutex_t base_mu = PTHREAD_MUTEX_INITIALIZER;
static double base_checked_at;
static volatile int need_reload;
static unsigned long n_reopen, n_req, n_repair;

static int is_share(int fd) { struct statfs f; return fstatfs(fd, &f) == 0 && (unsigned long)f.f_type == VIRTIOFS_MAGIC; }
static int base_healthy(void) {
    int fd = openat(basefd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0) return 0;
    int ok = is_share(fd);
    close(fd);
    return ok;
}
/* Re-open the base from RAW's path. 1 when a live share was adopted. base_mu held. */
static int reopen_base_locked(const char *why) {
    int nfd = open(raw_path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (nfd < 0) { logm("re-open (%s): %s: %s — keeping the old base", why, raw_path, strerror(errno)); return 0; }
    if (!is_share(nfd)) { logm("re-open (%s): %s is not the virtio-fs share (yet) — keeping the old base", why, raw_path); close(nfd); return 0; }
    if (dup3(nfd, basefd, O_CLOEXEC) < 0) { logm("re-open (%s): dup3: %s", why, strerror(errno)); close(nfd); return 0; }
    close(nfd);
    n_reopen++; need_reload = 1;
    logm("re-open (%s): base re-opened from %s", why, raw_path);
    return 1;
}
/* 1.1.1: the base is dead AND RAW is not the share again yet — the wake's re-mount is between its umount and
 * its bind (a request arrived before SIGUSR1). Hold the request until RAW is back (≤ 5 s, every 50 ms) rather
 * than answer ENOENT now: a LOOKUP answered ENOENT makes the kernel drop that dentry, and a program whose
 * current folder it is loses it ("/workspace/sub (deleted)", getcwd fails) — the bug the view exists to
 * prevent. 1 when the base is healthy again (retry the request). */
static int wait_for_base(int err) {
    if (err != ENOENT && err != ESTALE && err != EIO && err != ENOTCONN) return 0;
    /* An ordinary ENOENT (a name that is not there) costs one health check per 50 ms at most. */
    static double healthy_at;
    pthread_mutex_lock(&base_mu);
    double t0 = now_ms();
    int dead = t0 - healthy_at >= 50 && !base_healthy();
    if (!dead) healthy_at = t0;
    pthread_mutex_unlock(&base_mu);
    if (!dead) return 0;
    for (int i = 0; i < 100; i++) {
        struct timespec ts = {0, 50 * 1000 * 1000};
        nanosleep(&ts, NULL);
        pthread_mutex_lock(&base_mu);
        int ok = base_healthy();
        if (!ok) { int nfd = open(raw_path, O_RDONLY | O_DIRECTORY | O_CLOEXEC); if (nfd >= 0) { int sh = is_share(nfd); close(nfd); if (sh) ok = reopen_base_locked("a request waited"); } }
        if (ok) n_repair++;
        pthread_mutex_unlock(&base_mu);
        if (ok) { if (i > 0) logm("a request waited %d ms for the share to come back", (i + 1) * 50); return 1; }
    }
    logm("a request waited 5 s for the share — answering its error");
    return 0;
}

/* A request's syscall failed in a way a dead base explains: repair (at most every 50 ms). */
static int maybe_repair(int err) {
    if (err != ENOENT && err != ESTALE && err != EIO && err != ENOTCONN) return 0;
    pthread_mutex_lock(&base_mu);
    double t = now_ms(); int r = 0;
    if (t - base_checked_at >= 50) {
        base_checked_at = t;
        if (!base_healthy()) { r = reopen_base_locked("a request failed"); if (r) n_repair++; }
    }
    pthread_mutex_unlock(&base_mu);
    return r;
}

/* ------------------------------------------------------------------ replies */
static void reply_iov(uint64_t unique, int err, struct iovec *iov, int n) {
    struct fuse_out_header oh; size_t len = sizeof oh;
    for (int i = 1; i < n; i++) len += iov[i].iov_len;
    oh.len = (uint32_t)(err ? sizeof oh : len); oh.error = err ? -err : 0; oh.unique = unique;
    iov[0].iov_base = &oh; iov[0].iov_len = sizeof oh;
    if (writev(fusefd, iov, err ? 1 : n) < 0 && errno != ENOENT) logm("reply: %s", strerror(errno));
}
static void reply_err(uint64_t unique, int err) { struct iovec iov[1]; reply_iov(unique, err, iov, 1); }
static void reply_ok(uint64_t unique, const void *a, size_t al, const void *b, size_t bl) {
    struct iovec iov[3] = {{0, 0}, {(void *)a, al}, {(void *)b, bl}};
    reply_iov(unique, 0, iov, b ? 3 : (a ? 2 : 1));
}

static void tv(double s, uint64_t *sec, uint32_t *nsec) { *sec = (uint64_t)s; *nsec = (uint32_t)((s - (double)*sec) * 1e9); }
static void fill_attr(struct fuse_attr *a, const struct stat *st, int cls) {
    memset(a, 0, sizeof *a);
    a->ino = st->st_ino; a->size = (uint64_t)st->st_size; a->blocks = (uint64_t)st->st_blocks;
    a->atime = (uint64_t)st->st_atim.tv_sec; a->atimensec = (uint32_t)st->st_atim.tv_nsec;
    a->mtime = (uint64_t)st->st_mtim.tv_sec; a->mtimensec = (uint32_t)st->st_mtim.tv_nsec;
    a->ctime = (uint64_t)st->st_ctim.tv_sec; a->ctimensec = (uint32_t)st->st_ctim.tv_nsec;
    a->mode = st->st_mode; a->nlink = (uint32_t)st->st_nlink; a->uid = st->st_uid; a->gid = st->st_gid;
    a->rdev = (uint32_t)st->st_rdev; a->blksize = (uint32_t)st->st_blksize;
    if (cls == C_EXCL) a->mode &= S_IFMT;   /* ---------- / d--------- */
    if (cls == C_RO) a->mode &= ~0222u;     /* no write bits shown */
}
static void fill_entry(struct fuse_entry_out *eo, uint64_t id, const struct stat *st, int cls) {
    memset(eo, 0, sizeof *eo);
    eo->nodeid = id; eo->generation = 1;
    tv(tmo, &eo->entry_valid, &eo->entry_valid_nsec); tv(tmo, &eo->attr_valid, &eo->attr_valid_nsec);
    fill_attr(&eo->attr, st, cls);
}

/* ------------------------------------------------------------------ file handles */
/* fh = generation << 48 | fd (files) — or | 1<<47 | slot (directories). A dead worker's handles never
 * name one of ours. */
#define FH_DIR (1ULL << 47)
typedef struct { uint64_t nodeid; int flags; int used; } fdinfo_t;
static fdinfo_t *fdi; static int fdi_cap;
static uint64_t fh_file(int fd, uint64_t nodeid, int flags) {
    pthread_mutex_lock(&mu);
    if (fd >= fdi_cap) {
        int nc = fdi_cap ? fdi_cap : 1024; while (nc <= fd) nc *= 2;
        fdinfo_t *x = realloc(fdi, sizeof *fdi * (size_t)nc);
        if (x) { memset(x + fdi_cap, 0, sizeof *x * (size_t)(nc - fdi_cap)); fdi = x; fdi_cap = nc; }
    }
    if (fd < fdi_cap) { fdi[fd].nodeid = nodeid; fdi[fd].flags = flags; fdi[fd].used = 1; }
    pthread_mutex_unlock(&mu);
    return (wgen << 48) | (uint64_t)fd;
}
static int fh_fd(uint64_t fh) {
    if ((fh >> 48) != wgen || (fh & FH_DIR)) return -1;
    return (int)(fh & 0xffffffffULL);
}
/* A descriptor that died with a hibernation: re-open the file by its path (base repaired first). */
static int fh_heal(int fd, int err) {
    /* EBADF too: a virtio-fs handle from before a hibernation is unknown to the new server (measured) —
     * the descriptor itself is ours (fh_fd checked the generation, fdi says it is open). */
    if (err != EIO && err != ENOENT && err != ESTALE && err != ENOTCONN && err != EBADF) return 0;
    maybe_repair(err);
    char path[PATHMAX]; int flags = 0, ok = 0;
    pthread_mutex_lock(&mu);
    if (fd < fdi_cap && fdi[fd].used && R) {
        node *n = node_by_id(fdi[fd].nodeid);
        if (n && node_path(n, path, sizeof path) == 0) { flags = fdi[fd].flags; ok = 1; }
    }
    pthread_mutex_unlock(&mu);
    if (!ok) return 0;
    int nfd = openat(basefd, at(path), (flags & ~(O_CREAT | O_EXCL | O_TRUNC)) | O_CLOEXEC | O_NOFOLLOW);
    if (nfd < 0) return 0;
    int r = dup3(nfd, fd, O_CLOEXEC) >= 0;
    close(nfd);
    if (r) logm("re-opened a file handle by its path after it died (%s)", strerror(err));
    return r;
}

typedef struct { char *name; uint64_t ino; uint8_t type; } dent_t;
typedef struct { uint64_t nodeid; dent_t *e; size_t n; int used; } dirh_t;
static dirh_t *dh; static size_t ndh;

/* ------------------------------------------------------------------ requests */
typedef struct { struct fuse_in_header *in; char *arg; char *out; } req_t;

/* A handler returns 0 when it replied, or a POSITIVE errno to answer. `sys` (set by SYS()) marks an
 * error from a syscall on the base — the dispatcher may repair the base and retry once. */
static __thread int sys_err;
#define SYS(e) (sys_err = 1, (e))

static int lookup_parent(uint64_t id, node **p, int *pcls, char *ppath) {
    *p = node_by_id(id);
    if (!*p) return ESTALE;
    *pcls = classify_node(*p, ppath);
    if (node_path(*p, ppath, PATHMAX) < 0) return ESTALE;
    return 0;
}

static int op_lookup(req_t *q) {
    const char *name = q->arg; char pp[PATHMAX], c[PATHMAX]; node *p; int pcls, e;
    pthread_mutex_lock(&mu);
    if ((e = lookup_parent(q->in->nodeid, &p, &pcls, pp))) { pthread_mutex_unlock(&mu); return e; }
    if (pcls == C_EXCL) { pthread_mutex_unlock(&mu); return excl_err(); }
    if ((e = -join(c, sizeof c, pp, name))) { pthread_mutex_unlock(&mu); return e; }
    pthread_mutex_unlock(&mu);
    struct stat st;
    if (fstatat(basefd, c, &st, AT_SYMLINK_NOFOLLOW) != 0) return SYS(errno);
    pthread_mutex_lock(&mu);
    p = node_by_id(q->in->nodeid);
    if (!p) { pthread_mutex_unlock(&mu); return ESTALE; }
    int cls = classify_child(p, c, S_ISDIR(st.st_mode));
    if (cls == C_EXCL && R->hide) { pthread_mutex_unlock(&mu); return ENOENT; }
    node *n = child_get(p, name, st.st_mode);
    if (!n) { pthread_mutex_unlock(&mu); return ENOMEM; }
    n->nlookup++;
    char nb[PATHMAX]; cls = classify_node(n, nb);
    struct fuse_entry_out eo; fill_entry(&eo, n->id, &st, cls);
    pthread_mutex_unlock(&mu);
    reply_ok(q->in->unique, &eo, sizeof eo, NULL, 0);
    return 0;
}

static int node_and_class(uint64_t id, char *path, int *cls) {
    pthread_mutex_lock(&mu);
    node *n = node_by_id(id);
    if (!n) { pthread_mutex_unlock(&mu); return ESTALE; }
    *cls = classify_node(n, path);
    int r = node_path(n, path, PATHMAX);
    pthread_mutex_unlock(&mu);
    return r < 0 ? -r : 0;
}

static int op_getattr(req_t *q) {
    struct fuse_getattr_in *gi = (void *)q->arg; char path[PATHMAX]; int cls, e; struct stat st;
    int fd = (gi->getattr_flags & FUSE_GETATTR_FH) ? fh_fd(gi->fh) : -1;
    if (fd >= 0) {
        pthread_mutex_lock(&mu); node *n = node_by_id(q->in->nodeid); cls = n ? classify_node(n, path) : C_NONE; pthread_mutex_unlock(&mu);
        if (fstat(fd, &st) != 0) return SYS(errno);
    } else {
        if ((e = node_and_class(q->in->nodeid, path, &cls))) return e;
        if (cls == C_EXCL && R->hide) return ENOENT;
        if (fstatat(basefd, at(path), &st, AT_SYMLINK_NOFOLLOW) != 0) return SYS(errno);
    }
    struct fuse_attr_out ao; memset(&ao, 0, sizeof ao);
    tv(tmo, &ao.attr_valid, &ao.attr_valid_nsec); fill_attr(&ao.attr, &st, cls);
    reply_ok(q->in->unique, &ao, sizeof ao, NULL, 0);
    return 0;
}

static int op_setattr(req_t *q) {
    struct fuse_setattr_in *si = (void *)q->arg; char path[PATHMAX]; int cls, e;
    if ((e = node_and_class(q->in->nodeid, path, &cls))) return e;
    if ((e = may_mutate(cls))) return e;
    int fd = (si->valid & FATTR_FH) ? fh_fd(si->fh) : -1;
    if (si->valid & FATTR_MODE) {
        if (fd >= 0 ? fchmod(fd, si->mode & 07777) : fchmodat(basefd, at(path), si->mode & 07777, 0)) return SYS(errno);
    }
    if (si->valid & (FATTR_UID | FATTR_GID)) {
        uid_t u = (si->valid & FATTR_UID) ? si->uid : (uid_t)-1; gid_t g = (si->valid & FATTR_GID) ? si->gid : (gid_t)-1;
        if (fd >= 0 ? fchown(fd, u, g) : fchownat(basefd, at(path), u, g, AT_SYMLINK_NOFOLLOW)) return SYS(errno);
    }
    if (si->valid & FATTR_SIZE) {
        if (fd >= 0) { if (ftruncate(fd, (off_t)si->size)) return SYS(errno); }
        else {
            int tfd = openat(basefd, at(path), O_WRONLY | O_CLOEXEC | O_NOFOLLOW);
            if (tfd < 0) return SYS(errno);
            int r = ftruncate(tfd, (off_t)si->size) ? errno : 0; close(tfd);
            if (r) return SYS(r);
        }
    }
    if (si->valid & (FATTR_ATIME | FATTR_MTIME | FATTR_ATIME_NOW | FATTR_MTIME_NOW)) {
        struct timespec t[2] = {{0, UTIME_OMIT}, {0, UTIME_OMIT}};
        if (si->valid & FATTR_ATIME) { t[0].tv_sec = (time_t)si->atime; t[0].tv_nsec = si->atimensec; }
        if (si->valid & FATTR_ATIME_NOW) t[0].tv_nsec = UTIME_NOW;
        if (si->valid & FATTR_MTIME) { t[1].tv_sec = (time_t)si->mtime; t[1].tv_nsec = si->mtimensec; }
        if (si->valid & FATTR_MTIME_NOW) t[1].tv_nsec = UTIME_NOW;
        if (fd >= 0 ? futimens(fd, t) : utimensat(basefd, at(path), t, AT_SYMLINK_NOFOLLOW)) return SYS(errno);
    }
    struct stat st;
    if (fd >= 0 ? fstat(fd, &st) : fstatat(basefd, at(path), &st, AT_SYMLINK_NOFOLLOW)) return SYS(errno);
    struct fuse_attr_out ao; memset(&ao, 0, sizeof ao);
    tv(tmo, &ao.attr_valid, &ao.attr_valid_nsec); fill_attr(&ao.attr, &st, cls);
    reply_ok(q->in->unique, &ao, sizeof ao, NULL, 0);
    return 0;
}

static int op_access(req_t *q) {
    struct fuse_access_in *ai = (void *)q->arg; char path[PATHMAX]; int cls, e;
    if ((e = node_and_class(q->in->nodeid, path, &cls))) return e;
    if (cls == C_EXCL) return excl_err();
    if (cls == C_RO && (ai->mask & W_OK)) return EROFS;
    if (faccessat(basefd, at(path), (int)ai->mask, 0)) return SYS(errno);
    reply_ok(q->in->unique, NULL, 0, NULL, 0);
    return 0;
}

static int op_readlink(req_t *q) {
    char path[PATHMAX], b[PATHMAX]; int cls, e;
    if ((e = node_and_class(q->in->nodeid, path, &cls))) return e;
    if (cls == C_EXCL) return excl_err();
    ssize_t n = readlinkat(basefd, at(path), b, sizeof b);
    if (n < 0) return SYS(errno);
    reply_ok(q->in->unique, b, (size_t)n, NULL, 0);
    return 0;
}

static int op_open(req_t *q) {
    struct fuse_open_in *oi = (void *)q->arg; char path[PATHMAX]; int cls, e;
    if ((e = node_and_class(q->in->nodeid, path, &cls))) return e;
    int acc = (int)oi->flags & O_ACCMODE;
    if (cls == C_EXCL) return excl_err();
    if (cls == C_RO && (acc != O_RDONLY || (oi->flags & O_TRUNC))) return EROFS;
    int flags = ((int)oi->flags & ~(O_CREAT | O_EXCL | O_NOCTTY)) | O_CLOEXEC | O_NOFOLLOW;
    int fd = openat(basefd, at(path), flags);
    if (fd < 0) return SYS(errno);
    struct fuse_open_out oo; memset(&oo, 0, sizeof oo);
    oo.fh = fh_file(fd, q->in->nodeid, flags);
    reply_ok(q->in->unique, &oo, sizeof oo, NULL, 0);
    return 0;
}

/* The caller's credentials for anything that makes an inode, as a raw access would have them. */
struct creds { uid_t u; gid_t g; };
static struct creds as_caller(const struct fuse_in_header *in) {
    struct creds c = {(uid_t)setfsuid((uid_t)-1), (gid_t)setfsgid((gid_t)-1)};
    setfsgid(in->gid); setfsuid(in->uid);
    return c;
}
static void restore_creds(struct creds c) { setfsuid(c.u); setfsgid(c.g); }

/* The common start of every op that adds a name in a directory: the parent, its class, the child's
 * path and the class the new name would have. */
static int prepare_new(uint64_t pid, const char *name, int isdir, char *c, node **pp, int *ccls) {
    char ppath[PATHMAX]; int pcls, e;
    if ((e = lookup_parent(pid, pp, &pcls, ppath))) return e;
    if ((e = parent_allows_entries(pcls))) return e;
    if ((e = -join(c, PATHMAX, ppath, name))) return e;
    *ccls = classify_child(*pp, c, isdir);
    return may_create(*ccls);
}

static int finish_new(req_t *q, const char *name, const char *c, const void *extra, size_t extral) {
    struct stat st;
    if (fstatat(basefd, c, &st, AT_SYMLINK_NOFOLLOW) != 0) return SYS(errno);
    pthread_mutex_lock(&mu);
    node *p = node_by_id(q->in->nodeid);
    node *n = p ? child_get(p, name, st.st_mode) : NULL;
    if (!n) { pthread_mutex_unlock(&mu); return p ? ENOMEM : ESTALE; }
    n->nlookup++;
    char nb[PATHMAX]; int cls = classify_node(n, nb);
    struct fuse_entry_out eo; fill_entry(&eo, n->id, &st, cls);
    pthread_mutex_unlock(&mu);
    reply_ok(q->in->unique, &eo, sizeof eo, extra, extral);
    return 0;
}

static int op_create(req_t *q) {
    struct fuse_create_in *ci = (void *)q->arg; const char *name = q->arg + sizeof *ci;
    char c[PATHMAX]; node *p; int ccls, e;
    pthread_mutex_lock(&mu); e = prepare_new(q->in->nodeid, name, 0, c, &p, &ccls); pthread_mutex_unlock(&mu);
    if (e) return e;
    int flags = ((int)ci->flags & ~O_NOCTTY) | O_CREAT | O_CLOEXEC | O_NOFOLLOW;
    struct creds cr = as_caller(q->in);
    int fd = openat(basefd, c, flags, ci->mode);
    int err = errno;
    restore_creds(cr);
    if (fd < 0) return SYS(err);
    struct fuse_open_out oo; memset(&oo, 0, sizeof oo);
    /* the node id is only known after finish_new; record the handle with the parent and fix it below */
    struct stat st;
    if (fstat(fd, &st) != 0) { e = errno; close(fd); return SYS(e); }
    pthread_mutex_lock(&mu);
    p = node_by_id(q->in->nodeid);
    node *n = p ? child_get(p, name, st.st_mode) : NULL;
    pthread_mutex_unlock(&mu);
    if (!n) { close(fd); return ESTALE; }
    oo.fh = fh_file(fd, n->id, flags & ~(O_CREAT | O_EXCL | O_TRUNC));
    if ((e = finish_new(q, name, c, &oo, sizeof oo))) { close(fd); return e; }
    return 0;
}

static int op_mknod_mkdir_symlink(req_t *q) {
    const char *name, *target = NULL; uint32_t mode = 0; dev_t rdev = 0; int isdir = 0;
    switch (q->in->opcode) {
    case FUSE_MKDIR: { struct fuse_mkdir_in *m = (void *)q->arg; name = q->arg + sizeof *m; mode = m->mode; isdir = 1; break; }
    case FUSE_MKNOD: { struct fuse_mknod_in *m = (void *)q->arg; name = q->arg + sizeof *m; mode = m->mode; rdev = m->rdev; break; }
    default: name = q->arg; target = name + strlen(name) + 1; break; /* SYMLINK: name, then target */
    }
    char c[PATHMAX]; node *p; int ccls, e;
    pthread_mutex_lock(&mu); e = prepare_new(q->in->nodeid, name, isdir, c, &p, &ccls); pthread_mutex_unlock(&mu);
    if (e) return e;
    struct creds cr = as_caller(q->in);
    int r = q->in->opcode == FUSE_MKDIR ? mkdirat(basefd, c, mode)
          : q->in->opcode == FUSE_MKNOD ? mknodat(basefd, c, mode, rdev) : symlinkat(target, basefd, c);
    int err = errno;
    restore_creds(cr);
    if (r) return SYS(err);
    return finish_new(q, name, c, NULL, 0);
}

static int op_link(req_t *q) {
    struct fuse_link_in *li = (void *)q->arg; const char *name = q->arg + sizeof *li;
    char c[PATHMAX], src[PATHMAX]; node *p; int ccls, scls, e;
    pthread_mutex_lock(&mu);
    node *s = node_by_id(li->oldnodeid);
    if (!s) { pthread_mutex_unlock(&mu); return ESTALE; }
    scls = classify_node(s, src);
    e = node_path(s, src, sizeof src) < 0 ? ESTALE : 0;
    /* a second name for a read-only or locked file would be a way around the rules */
    if (!e && scls != C_NONE) e = scls == C_EXCL ? excl_err() : EROFS;
    if (!e) e = prepare_new(q->in->nodeid, name, 0, c, &p, &ccls);
    pthread_mutex_unlock(&mu);
    if (e) return e;
    struct creds cr = as_caller(q->in);
    int r = linkat(basefd, src, basefd, c, 0), err = errno;
    restore_creds(cr);
    if (r) return SYS(err);
    return finish_new(q, name, c, NULL, 0);
}

static int op_unlink(req_t *q) {
    const char *name = q->arg; char pp[PATHMAX], c[PATHMAX]; node *p; int pcls, e;
    pthread_mutex_lock(&mu);
    if (!(e = lookup_parent(q->in->nodeid, &p, &pcls, pp)) && !(e = parent_allows_entries(pcls))) e = -join(c, sizeof c, pp, name);
    pthread_mutex_unlock(&mu);
    if (e) return e;
    struct stat st;
    if (fstatat(basefd, c, &st, AT_SYMLINK_NOFOLLOW) != 0) return SYS(errno);
    pthread_mutex_lock(&mu);
    p = node_by_id(q->in->nodeid);
    e = p ? may_mutate(classify_child(p, c, S_ISDIR(st.st_mode))) : ESTALE;
    pthread_mutex_unlock(&mu);
    if (e) return e;
    if (unlinkat(basefd, c, q->in->opcode == FUSE_RMDIR ? AT_REMOVEDIR : 0)) return SYS(errno);
    pthread_mutex_lock(&mu);
    if ((p = node_by_id(q->in->nodeid))) node_detach(child_find(p, name));
    pthread_mutex_unlock(&mu);
    reply_ok(q->in->unique, NULL, 0, NULL, 0);
    return 0;
}

static int op_rename(req_t *q) {
    uint64_t nd; unsigned fl = 0; const char *on;
    if (q->in->opcode == FUSE_RENAME) { struct fuse_rename_in *ri = (void *)q->arg; nd = ri->newdir; on = q->arg + sizeof *ri; }
    else { struct fuse_rename2_in *ri = (void *)q->arg; nd = ri->newdir; fl = ri->flags; on = q->arg + sizeof *ri; }
    const char *nn = on + strlen(on) + 1;
    char sp[PATHMAX], dp[PATHMAX], c1[PATHMAX], c2[PATHMAX]; node *s, *d; int scls, dcls, e;
    pthread_mutex_lock(&mu);
    if (!(e = lookup_parent(q->in->nodeid, &s, &scls, sp)) && !(e = parent_allows_entries(scls))
        && !(e = lookup_parent(nd, &d, &dcls, dp)) && !(e = parent_allows_entries(dcls))
        && !(e = -join(c1, sizeof c1, sp, on))) e = -join(c2, sizeof c2, dp, nn);
    pthread_mutex_unlock(&mu);
    if (e) return e;
    struct stat a, b; int bexists;
    if (fstatat(basefd, c1, &a, AT_SYMLINK_NOFOLLOW) != 0) return SYS(errno);
    bexists = fstatat(basefd, c2, &b, AT_SYMLINK_NOFOLLOW) == 0;
    pthread_mutex_lock(&mu);
    s = node_by_id(q->in->nodeid); d = node_by_id(nd);
    if (!s || !d) e = ESTALE;
    if (!e) e = may_mutate(classify_child(s, c1, S_ISDIR(a.st_mode)));
    if (!e) {
        int c2cls = classify_child(d, c2, bexists ? S_ISDIR(b.st_mode) : S_ISDIR(a.st_mode));
        e = (fl & RENAME_EXCHANGE) ? may_mutate(c2cls) : may_create(c2cls);
        /* what the moved entry would BE at its new name must not be weaker than what it is now */
        if (!e && classify_child(d, c2, S_ISDIR(a.st_mode)) != C_NONE && !(fl & RENAME_EXCHANGE)) e = may_create(classify_child(d, c2, S_ISDIR(a.st_mode)));
    }
    if (!e && S_ISDIR(a.st_mode) && dir_rename_sensitive(c1)) e = EACCES;
    if (!e && (fl & RENAME_EXCHANGE) && bexists && S_ISDIR(b.st_mode) && dir_rename_sensitive(c2)) e = EACCES;
    pthread_mutex_unlock(&mu);
    if (e) return e;
    if (syscall(SYS_renameat2, basefd, c1, basefd, c2, fl)) return SYS(errno);
    pthread_mutex_lock(&mu);
    s = node_by_id(q->in->nodeid); d = node_by_id(nd);
    node *from = s ? child_find(s, on) : NULL, *to = d ? child_find(d, nn) : NULL;
    if (fl & RENAME_EXCHANGE) { if (from) node_detach(from); if (to) node_detach(to); }
    else if (from && d) {
        if (to && to != from) node_detach(to);
        h_remove_name(from);
        char *nname = strdup(nn);
        if (nname) {
            free(from->name); from->name = nname;
            if (from->parent != d) { from->parent->nkids--; node *op = from->parent; from->parent = d; d->nkids++; node_try_free(op); }
            h_insert_name(from);
        } else node_detach(from);
        if (S_ISDIR(a.st_mode)) struct_gen++; else from->rgen = 0;
    }
    pthread_mutex_unlock(&mu);
    reply_ok(q->in->unique, NULL, 0, NULL, 0);
    return 0;
}

static int op_read(req_t *q) {
    struct fuse_read_in *ri = (void *)q->arg;
    int fd = fh_fd(ri->fh);
    if (fd < 0) return EBADF;
    size_t sz = ri->size > BUFSZ - 4096 ? BUFSZ - 4096 : ri->size;
    ssize_t n = pread(fd, q->out, sz, (off_t)ri->offset);
    if (n < 0 && fh_heal(fd, errno)) n = pread(fd, q->out, sz, (off_t)ri->offset);
    if (n < 0) return errno;
    reply_ok(q->in->unique, q->out, (size_t)n, NULL, 0);
    return 0;
}

static int op_write(req_t *q) {
    struct fuse_write_in *wi = (void *)q->arg;
    int fd = fh_fd(wi->fh);
    if (fd < 0) return EBADF;
    const char *data = q->arg + sizeof *wi;
    ssize_t n = pwrite(fd, data, wi->size, (off_t)wi->offset);
    if (n < 0 && fh_heal(fd, errno)) n = pwrite(fd, data, wi->size, (off_t)wi->offset);
    if (n < 0) return errno;
    struct fuse_write_out wo; memset(&wo, 0, sizeof wo); wo.size = (uint32_t)n;
    reply_ok(q->in->unique, &wo, sizeof wo, NULL, 0);
    return 0;
}

static int op_release(req_t *q) {
    struct fuse_release_in *ri = (void *)q->arg;
    int fd = fh_fd(ri->fh);
    if (fd >= 0) {
        pthread_mutex_lock(&mu); if (fd < fdi_cap) fdi[fd].used = 0; pthread_mutex_unlock(&mu);
        close(fd);
    }
    reply_ok(q->in->unique, NULL, 0, NULL, 0);
    return 0;
}

static int op_fsync(req_t *q) {
    struct fuse_fsync_in *fi = (void *)q->arg;
    int fd = fh_fd(fi->fh);
    if (fd < 0) return EBADF;
    if ((fi->fsync_flags & 1) ? fdatasync(fd) : fsync(fd)) return errno;
    reply_ok(q->in->unique, NULL, 0, NULL, 0);
    return 0;
}

static int op_fallocate(req_t *q) {
    struct fuse_fallocate_in *fa = (void *)q->arg;
    int fd = fh_fd(fa->fh);
    if (fd < 0) return EBADF;
    if (fallocate(fd, (int)fa->mode, (off_t)fa->offset, (off_t)fa->length)) return errno;
    reply_ok(q->in->unique, NULL, 0, NULL, 0);
    return 0;
}

static int op_lseek(req_t *q) {
    struct fuse_lseek_in *li = (void *)q->arg;
    int fd = fh_fd(li->fh);
    if (fd < 0) return EBADF;
    off_t r = lseek(fd, (off_t)li->offset, (int)li->whence);
    if (r < 0) return errno;
    struct fuse_lseek_out lo = {.offset = (uint64_t)r};
    reply_ok(q->in->unique, &lo, sizeof lo, NULL, 0);
    return 0;
}

static int op_statfs(req_t *q) {
    struct statvfs s;
    if (fstatvfs(basefd, &s)) return SYS(errno);
    struct fuse_statfs_out so; memset(&so, 0, sizeof so);
    so.st.blocks = s.f_blocks; so.st.bfree = s.f_bfree; so.st.bavail = s.f_bavail; so.st.files = s.f_files; so.st.ffree = s.f_ffree;
    so.st.bsize = (uint32_t)s.f_bsize; so.st.namelen = (uint32_t)s.f_namemax; so.st.frsize = (uint32_t)s.f_frsize;
    reply_ok(q->in->unique, &so, sizeof so, NULL, 0);
    return 0;
}

/* Directory handles: the listing is read (and filtered) at the first READDIR(PLUS) of offset 0, so a
 * rewind sees the directory as it is now. */
static int op_opendir(req_t *q) {
    char path[PATHMAX]; int cls, e;
    if ((e = node_and_class(q->in->nodeid, path, &cls))) return e;
    if (cls == C_EXCL) return excl_err();
    int fd = openat(basefd, at(path), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW); /* exists and is ours to read */
    if (fd < 0) return SYS(errno);
    close(fd);
    pthread_mutex_lock(&mu);
    size_t i; for (i = 0; i < ndh && dh[i].used; i++) ;
    if (i == ndh) {
        dirh_t *x = realloc(dh, sizeof *dh * (ndh + 64));
        if (!x) { pthread_mutex_unlock(&mu); return ENOMEM; }
        memset(x + ndh, 0, sizeof *dh * 64); dh = x; ndh += 64;
    }
    dh[i].used = 1; dh[i].nodeid = q->in->nodeid; dh[i].e = NULL; dh[i].n = 0;
    pthread_mutex_unlock(&mu);
    struct fuse_open_out oo; memset(&oo, 0, sizeof oo);
    oo.fh = (wgen << 48) | FH_DIR | (uint64_t)i;
    reply_ok(q->in->unique, &oo, sizeof oo, NULL, 0);
    return 0;
}
static void dir_free_entries(dirh_t *d) { for (size_t k = 0; k < d->n; k++) free(d->e[k].name); free(d->e); d->e = NULL; d->n = 0; }
static dirh_t *dir_of(uint64_t fh) {
    if ((fh >> 48) != wgen || !(fh & FH_DIR)) return NULL;
    size_t i = (size_t)(fh & 0xffffffffULL);
    return i < ndh && dh[i].used ? &dh[i] : NULL;
}
/* Read and filter the listing (mu NOT held). */
static int dir_fill(uint64_t nodeid, dent_t **out, size_t *nout) {
    char path[PATHMAX]; int cls, e;
    if ((e = node_and_class(nodeid, path, &cls))) return e;
    if (cls == C_EXCL) return excl_err();
    int fd = openat(basefd, at(path), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return SYS(errno);
    DIR *dp = fdopendir(fd);
    if (!dp) { e = errno; close(fd); return SYS(e); }
    size_t cap = 64, n = 0; dent_t *v = malloc(sizeof *v * cap); struct dirent *de;
    if (!v) { closedir(dp); return ENOMEM; }
    while ((de = readdir(dp))) {
        if (n == cap) { dent_t *x = realloc(v, sizeof *v * cap * 2); if (!x) break; v = x; cap *= 2; }
        v[n].name = strdup(de->d_name); v[n].ino = de->d_ino; v[n].type = de->d_type;
        if (!v[n].name) break;
        if (v[n].type == DT_UNKNOWN && strcmp(de->d_name, ".") && strcmp(de->d_name, "..")) {
            struct stat st; char c[PATHMAX];
            if (join(c, sizeof c, path, de->d_name) == 0 && fstatat(basefd, c, &st, AT_SYMLINK_NOFOLLOW) == 0) v[n].type = (uint8_t)(IFTODT(st.st_mode));
        }
        n++;
    }
    closedir(dp);
    /* The view's ROOT: the share's own root listing has no ".." (virtio-fs answers "." only), so
     * `ls -la /workspace` showed one entry where every subfolder shows two. A directory always lists
     * both; ".." of a mount's root is the folder it is mounted in (its inode, read once at start —
     * never through this mount). */
    if (nodeid == FUSE_ROOT_ID) {
        int have[2] = {0, 0};
        for (size_t k = 0; k < n; k++) { if (!strcmp(v[k].name, ".")) have[0] = 1; else if (!strcmp(v[k].name, "..")) have[1] = 1; }
        for (int w = 1; w >= 0; w--) {          /* "..", then "." in front of it: listed first, as usual */
            if (have[w]) continue;
            if (n == cap) { dent_t *x = realloc(v, sizeof *v * (cap + 2)); if (!x) break; v = x; cap += 2; }
            char *name = strdup(w ? ".." : ".");
            if (!name) break;
            memmove(v + 1, v, sizeof *v * n);
            v[0].name = name; v[0].ino = w ? mnt_parent_ino : 1; v[0].type = DT_DIR;
            n++;
        }
    }
    /* filter: a hidden name is not listed */
    pthread_mutex_lock(&mu);
    node *p = node_by_id(nodeid); size_t w = 0;
    for (size_t k = 0; k < n; k++) {
        int drop = 0;
        if (p && R->hide && strcmp(v[k].name, ".") && strcmp(v[k].name, "..")) {
            char c[PATHMAX];
            if (join(c, sizeof c, path, v[k].name) == 0 && classify_child(p, c, v[k].type == DT_DIR) == C_EXCL) drop = 1;
        }
        if (drop) free(v[k].name); else v[w++] = v[k];
    }
    pthread_mutex_unlock(&mu);
    *out = v; *nout = w;
    return 0;
}

static int op_readdir(req_t *q, int plus) {
    struct fuse_read_in *ri = (void *)q->arg;
    pthread_mutex_lock(&mu);
    dirh_t *d = dir_of(ri->fh);
    uint64_t nodeid = d ? d->nodeid : 0; int need = d && (ri->offset == 0 || !d->e);
    pthread_mutex_unlock(&mu);
    if (!d) return EBADF;
    if (need) {
        dent_t *v; size_t n; int e = dir_fill(nodeid, &v, &n);
        if (e) return e;
        pthread_mutex_lock(&mu);
        d = dir_of(ri->fh);
        if (d) { dir_free_entries(d); d->e = v; d->n = n; }
        pthread_mutex_unlock(&mu);
        if (!d) { for (size_t k = 0; k < n; k++) free(v[k].name); free(v); return EBADF; }
    }
    char dpath[PATHMAX]; int dcls, e;
    if ((e = node_and_class(nodeid, dpath, &dcls))) return e;
    size_t cap = ri->size > BUFSZ - 4096 ? BUFSZ - 4096 : ri->size, len = 0;
    for (uint64_t k = ri->offset;; k++) {
        pthread_mutex_lock(&mu);
        d = dir_of(ri->fh);
        if (!d || k >= d->n) { pthread_mutex_unlock(&mu); break; }
        char name[256 + 1]; snprintf(name, sizeof name, "%s", d->e[k].name);
        uint64_t ino = d->e[k].ino; uint8_t type = d->e[k].type;
        pthread_mutex_unlock(&mu);
        size_t nl = strlen(name);
        if (!plus) {
            size_t rec = FUSE_DIRENT_ALIGN(FUSE_NAME_OFFSET + nl);
            if (len + rec > cap) break;
            struct fuse_dirent *x = (void *)(q->out + len); memset(x, 0, rec);
            x->ino = ino; x->off = k + 1; x->namelen = (uint32_t)nl; x->type = type; memcpy(x->name, name, nl);
            len += rec;
            continue;
        }
        size_t rec = FUSE_DIRENT_ALIGN(FUSE_NAME_OFFSET_DIRENTPLUS + nl);
        if (len + rec > cap) break;
        struct fuse_direntplus *x = (void *)(q->out + len); memset(x, 0, rec);
        x->dirent.ino = ino; x->dirent.off = k + 1; x->dirent.namelen = (uint32_t)nl; x->dirent.type = type;
        memcpy(x->dirent.name, name, nl);
        if (strcmp(name, ".") && strcmp(name, "..")) {
            char c[PATHMAX]; struct stat st;
            if (join(c, sizeof c, dpath, name) == 0 && fstatat(basefd, c, &st, AT_SYMLINK_NOFOLLOW) == 0) {
                pthread_mutex_lock(&mu);
                node *p = node_by_id(nodeid);
                int ccls = p ? classify_child(p, c, S_ISDIR(st.st_mode)) : C_EXCL;
                if (p && !(ccls == C_EXCL && R->hide)) {
                    node *n = child_get(p, name, st.st_mode);
                    if (n) { n->nlookup++; char nb[PATHMAX]; fill_entry(&x->entry_out, n->id, &st, classify_node(n, nb)); }
                }
                pthread_mutex_unlock(&mu);
            }
        }
        len += rec;
    }
    reply_ok(q->in->unique, q->out, len, NULL, 0);
    return 0;
}

static int op_releasedir(req_t *q) {
    struct fuse_release_in *ri = (void *)q->arg;
    pthread_mutex_lock(&mu);
    dirh_t *d = dir_of(ri->fh);
    if (d) { dir_free_entries(d); d->used = 0; }
    pthread_mutex_unlock(&mu);
    reply_ok(q->in->unique, NULL, 0, NULL, 0);
    return 0;
}

static void forget_one(uint64_t id, uint64_t nl) {
    node *n = node_by_id(id);
    if (!n || n == &root_node) return;
    n->nlookup = n->nlookup > nl ? n->nlookup - nl : 0;
    node_try_free(n);
}

static unsigned negotiated_minor;
static int op_init(req_t *q) {
    struct fuse_init_in *ii = (void *)q->arg; struct fuse_init_out o; memset(&o, 0, sizeof o);
    o.major = FUSE_KERNEL_VERSION;
    o.minor = ii->minor < FUSE_KERNEL_MINOR_VERSION ? ii->minor : FUSE_KERNEL_MINOR_VERSION;
    negotiated_minor = o.minor;
    o.max_readahead = ii->max_readahead;
    uint32_t want = FUSE_ASYNC_READ | FUSE_ATOMIC_O_TRUNC | FUSE_BIG_WRITES | FUSE_AUTO_INVAL_DATA | FUSE_DO_READDIRPLUS
                  | FUSE_READDIRPLUS_AUTO | FUSE_PARALLEL_DIROPS | FUSE_MAX_PAGES | FUSE_CACHE_SYMLINKS;
    o.flags = ii->flags & want;
    o.max_background = 64; o.congestion_threshold = 48;
    o.max_write = MAX_PAGES * 4096; o.time_gran = 1; o.max_pages = MAX_PAGES;
    logm("INIT: kernel %u.%u, answered %u.%u, flags 0x%x", ii->major, ii->minor, o.major, o.minor, o.flags);
    reply_ok(q->in->unique, &o, sizeof o, NULL, 0);
    return 0;
}

static void dispatch(req_t *q) {
    __atomic_add_fetch(&n_req, 1, __ATOMIC_RELAXED);
    uint32_t op = q->in->opcode;
    switch (op) {
    case FUSE_FORGET: { struct fuse_forget_in *f = (void *)q->arg; pthread_mutex_lock(&mu); forget_one(q->in->nodeid, f->nlookup); pthread_mutex_unlock(&mu); return; }
    case FUSE_BATCH_FORGET: {
        struct fuse_batch_forget_in *b = (void *)q->arg; struct fuse_forget_one *o = (void *)(b + 1);
        pthread_mutex_lock(&mu); for (uint32_t i = 0; i < b->count; i++) forget_one(o[i].nodeid, o[i].nlookup); pthread_mutex_unlock(&mu);
        return;
    }
    case FUSE_INTERRUPT: return; /* every request is answered anyway */
    case FUSE_INIT: op_init(q); return;
    case FUSE_DESTROY: reply_ok(q->in->unique, NULL, 0, NULL, 0); return;
    }
    for (int attempt = 0; attempt < 2; attempt++) {
        sys_err = 0;
        int e;
        switch (op) {
        case FUSE_LOOKUP: e = op_lookup(q); break;
        case FUSE_GETATTR: e = op_getattr(q); break;
        case FUSE_SETATTR: e = op_setattr(q); break;
        case FUSE_ACCESS: e = op_access(q); break;
        case FUSE_READLINK: e = op_readlink(q); break;
        case FUSE_OPEN: e = op_open(q); break;
        case FUSE_CREATE: e = op_create(q); break;
        case FUSE_MKDIR: case FUSE_MKNOD: case FUSE_SYMLINK: e = op_mknod_mkdir_symlink(q); break;
        case FUSE_LINK: e = op_link(q); break;
        case FUSE_UNLINK: case FUSE_RMDIR: e = op_unlink(q); break;
        case FUSE_RENAME: case FUSE_RENAME2: e = op_rename(q); break;
        case FUSE_READ: e = op_read(q); break;
        case FUSE_WRITE: e = op_write(q); break;
        case FUSE_FLUSH: reply_ok(q->in->unique, NULL, 0, NULL, 0); e = 0; break;
        case FUSE_RELEASE: e = op_release(q); break;
        case FUSE_FSYNC: e = op_fsync(q); break;
        case FUSE_FALLOCATE: e = op_fallocate(q); break;
        case FUSE_LSEEK: e = op_lseek(q); break;
        case FUSE_STATFS: e = op_statfs(q); break;
        case FUSE_OPENDIR: e = op_opendir(q); break;
        case FUSE_READDIR: e = op_readdir(q, 0); break;
        case FUSE_READDIRPLUS: e = op_readdir(q, 1); break;
        case FUSE_RELEASEDIR: e = op_releasedir(q); break;
        case FUSE_FSYNCDIR: reply_ok(q->in->unique, NULL, 0, NULL, 0); e = 0; break;
        /* Extended attributes are not passed through (ENOSYS: the kernel stops asking); nor ioctl, poll,
         * copy_file_range (the kernel falls back to read/write), statx (it falls back to getattr). */
        default: e = ENOSYS; break;
        }
        if (!e) return;
        if (attempt == 0 && sys_err && (maybe_repair(e) || wait_for_base(e))) continue;
        reply_err(q->in->unique, e);
        return;
    }
}

/* ------------------------------------------------------------------ the worker */
static void *serve_thread(void *arg) {
    (void)arg;
    char *buf = malloc(BUFSZ), *out = malloc(BUFSZ);
    if (!buf || !out) { logm("out of memory"); _exit(70); }
    for (;;) {
        ssize_t n = read(fusefd, buf, BUFSZ);
        if (n < 0) {
            if (errno == EINTR || errno == EAGAIN || errno == ENOENT) continue;
            if (errno == ENODEV) { logm("the connection is gone (unmounted) — worker exits"); _exit(3); }
            logm("/dev/fuse read: %s — worker exits", strerror(errno)); _exit(1);
        }
        if ((size_t)n < sizeof(struct fuse_in_header)) continue;
        req_t q = {(struct fuse_in_header *)buf, buf + sizeof(struct fuse_in_header), out};
        dispatch(&q);
    }
    return NULL;
}

/* After new rules: drop the kernel's cached entries and attributes for every node it holds. */
static void invalidate_all(void) {
    typedef struct { uint64_t parent, id; char name[256]; } inv_t;
    pthread_mutex_lock(&mu);
    size_t cap = hcount + 1, k = 0;
    inv_t *v = malloc(sizeof *v * cap);
    if (v) for (size_t b = 0; b < hsize; b++)
        for (node *n = tid[b]; n; n = n->hid) {
            if (!n->name || !n->parent || k == cap) continue;
            v[k].parent = n->parent->id; v[k].id = n->id; snprintf(v[k].name, sizeof v[k].name, "%s", n->name); k++;
        }
    pthread_mutex_unlock(&mu);
    if (!v) return;
    for (size_t i = 0; i < k; i++) {
        struct fuse_out_header oh; struct fuse_notify_inval_entry_out ie; memset(&ie, 0, sizeof ie);
        size_t nl = strlen(v[i].name);
        ie.parent = v[i].parent; ie.namelen = (uint32_t)nl;
        /* 1.1.1: EXPIRE, never drop: a dropped (unhashed) dentry is "(deleted)" to every program whose
         * current folder it is — getcwd fails (Codex: "invalid cwd"). Expired, the kernel asks LOOKUP again on
         * the next walk and gets the new rules' answer (a hidden name: ENOENT, which drops it then). A kernel
         * before FUSE 7.38 ignores the flag (it was padding) and drops as before. */
        ie.flags = FUSE_EXPIRE_ONLY;
        struct iovec iov[3] = {{&oh, sizeof oh}, {&ie, sizeof ie}, {v[i].name, nl + 1}};
        oh.len = (uint32_t)(sizeof oh + sizeof ie + nl + 1); oh.error = FUSE_NOTIFY_INVAL_ENTRY; oh.unique = 0;
        (void)!writev(fusefd, iov, 3);
        struct fuse_notify_inval_inode_out ii; memset(&ii, 0, sizeof ii);
        ii.ino = v[i].id; ii.off = -1; ii.len = 0; /* attributes only; keep the page cache */
        struct iovec iov2[2] = {{&oh, sizeof oh}, {&ii, sizeof ii}};
        oh.len = (uint32_t)(sizeof oh + sizeof ii); oh.error = FUSE_NOTIFY_INVAL_INODE; oh.unique = 0;
        (void)!writev(fusefd, iov2, 2);
    }
    free(v);
}

static int same_file(const fileid_t *a, const fileid_t *b) {
    return a->present == b->present && (!a->present || (a->ino == b->ino && a->size == b->size
        && a->mt.tv_sec == b->mt.tv_sec && a->mt.tv_nsec == b->mt.tv_nsec));
}

static void reload(const char *why) {
    double t0 = now_ms();
    static int kept_logged;
    fileid_t was_ign = fid_ign, was_ro = fid_ro, was_conf = fid_conf;
    rules_t *nr = rules_build();
    if (!nr) { if (!kept_logged++) logm("rules (%s): the base is not reachable — keeping the last rules", why); return; }
    kept_logged = 0;
    pthread_mutex_lock(&mu);
    rules_t *old = R;
    nr->gen = ++rules_gen_counter;
    R = nr;
    pthread_mutex_unlock(&mu);
    /* The same files and conf as before (a wake's SIGUSR1, a poll that found nothing new): nothing to tell the
     * kernel. */
    int same = old && same_file(&was_ign, &fid_ign) && same_file(&was_ro, &fid_ro) && same_file(&was_conf, &fid_conf)
               && old->hide == nr->hide && old->fold == nr->fold;
    rules_free(old);
    if (old && !same) invalidate_all();
    logm("rules (%s): .dozignore %s (%d), .dozreadonly %s (%d), %d dropped, mode %s, fold %s — %.1f ms", why,
         nr->ign_present ? "present" : "absent", nr->n_ign, nr->ro_present ? "present" : "absent", nr->n_ro, nr->n_bad,
         nr->hide ? "hide" : "lock", nr->fold ? "on" : "off", now_ms() - t0);
    write_state();
}

static int fid_changed(const char *name, const fileid_t *f) {
    struct stat st;
    if (fstatat(basefd, name, &st, 0) != 0) return f->present;
    return !f->present || st.st_ino != f->ino || st.st_size != f->size || st.st_mtim.tv_sec != f->mt.tv_sec || st.st_mtim.tv_nsec != f->mt.tv_nsec;
}
static int conf_changed(void) {
    struct stat st;
    if (!conf_path || stat(conf_path, &st) != 0) return fid_conf.present;
    return !fid_conf.present || st.st_ino != fid_conf.ino || st.st_size != fid_conf.size || st.st_mtim.tv_nsec != fid_conf.mt.tv_nsec || st.st_mtim.tv_sec != fid_conf.mt.tv_sec;
}

static void write_state(void) {
    if (!state_path) return;
    char tmp[PATHMAX]; snprintf(tmp, sizeof tmp, "%s.tmp", state_path);
    FILE *f = fopen(tmp, "we");
    if (!f) return;
    pthread_mutex_lock(&mu);
    fprintf(f, "version=%s\nworker=%d\nrestarts=%d\nmode=%s\nfold=%d\nignore_file=%d\nignore_patterns=%d\nreadonly_file=%d\nreadonly_patterns=%d\ndropped=%d\nrules_gen=%llu\nnodes=%zu\n",
            DOZVIEW_VERSION, (int)getpid(), restarts, R && R->hide ? "hide" : "lock", R ? R->fold : 0, R ? R->ign_present : 0, R ? R->n_ign : 0,
            R ? R->ro_present : 0, R ? R->n_ro : 0, R ? R->n_bad : 0, (unsigned long long)(R ? R->gen : 0), hcount);
    pthread_mutex_unlock(&mu);
    fprintf(f, "requests=%lu\nreopens=%lu\nrepairs=%lu\nhealthy=%d\n", n_req, n_reopen, n_repair, base_healthy());
    fclose(f);
    rename(tmp, state_path);
}

static int worker_main(void) {
    umask(0);
    basefd = open(raw_path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (basefd < 0 || !is_share(basefd)) { logm("worker: %s is not the virtio-fs share (%s) — exiting", raw_path, basefd < 0 ? strerror(errno) : "wrong file system"); return 2; }
    root_node.id = FUSE_ROOT_ID; root_node.mode = S_IFDIR; root_node.nlookup = 1; root_node.name = (char *)"";
    if (mnt_path) {
        char parent[PATHMAX]; struct stat pst;
        snprintf(parent, sizeof parent, "%s", mnt_path);
        char *slash = strrchr(parent, '/');
        if (slash == parent) parent[1] = 0; else if (slash) *slash = 0;
        if (slash && stat(parent, &pst) == 0) mnt_parent_ino = pst.st_ino;
    }
    h_grow();
    reload("start");
    if (!R) { R = calloc(1, sizeof *R); if (!R) return 70; R->gen = ++rules_gen_counter; }
    sigset_t set; sigemptyset(&set);
    sigaddset(&set, SIGUSR1); sigaddset(&set, SIGUSR2); sigaddset(&set, SIGHUP); sigaddset(&set, SIGTERM); sigaddset(&set, SIGINT);
    pthread_sigmask(SIG_BLOCK, &set, NULL);
    for (int i = 0; i < nthreads; i++) {
        pthread_t t; pthread_attr_t a; pthread_attr_init(&a); pthread_attr_setstacksize(&a, 512 * 1024);
        if (pthread_create(&t, &a, serve_thread, NULL)) { logm("pthread_create: %s", strerror(errno)); return 1; }
        pthread_detach(t);
    }
    logm("worker %d serving %s at %s (%d threads, generation %llu, restart %d)", (int)getpid(), raw_path, mnt_path, nthreads, (unsigned long long)wgen, restarts);
    double last_state = now_ms();
    for (;;) {
        struct timespec to = {0, 250 * 1000000L}; siginfo_t si;
        int s = sigtimedwait(&set, &si, &to);
        if (s == SIGTERM || s == SIGINT) { logm("worker: SIGTERM — exiting"); return 0; }
        if (s == SIGUSR1) {
            pthread_mutex_lock(&base_mu); reopen_base_locked("SIGUSR1"); base_checked_at = now_ms(); pthread_mutex_unlock(&base_mu);
            reload("SIGUSR1");
            need_reload = 0;
            continue;
        }
        if (s == SIGHUP) { reload("SIGHUP"); need_reload = 0; continue; }
        if (s == SIGUSR2) { write_state(); continue; }
        /* the poll: a dead base is repaired here too (the backup to SIGUSR1); rules only through a live one */
        pthread_mutex_lock(&base_mu);
        int healthy = base_healthy();
        if (!healthy) { reopen_base_locked("poll"); healthy = base_healthy(); }
        base_checked_at = now_ms();
        pthread_mutex_unlock(&base_mu);
        if (!healthy) continue;
        if (need_reload || fid_changed(".dozignore", &fid_ign) || fid_changed(".dozreadonly", &fid_ro) || conf_changed()) {
            need_reload = 0;
            reload("a rule file changed");
        }
        if (now_ms() - last_state > 5000) { write_state(); last_state = now_ms(); }
    }
}

/* ------------------------------------------------------------------ the supervisor */
static volatile sig_atomic_t sv_sig;
static void sv_on(int s) { sv_sig = s; }

static int do_mount(void) {
    fusefd = open("/dev/fuse", O_RDWR); /* inherited by the worker on purpose */
    if (fusefd < 0) { fprintf(stderr, "dozview: /dev/fuse: %s\n", strerror(errno)); return -1; }
    char opts[256];
    snprintf(opts, sizeof opts, "fd=%d,rootmode=40000,user_id=0,group_id=0,allow_other,default_permissions", fusefd);
    if (mount("dozview", mnt_path, "fuse.dozview", MS_NOSUID | MS_NODEV, opts) != 0) {
        fprintf(stderr, "dozview: mount %s: %s\n", mnt_path, strerror(errno));
        close(fusefd); fusefd = -1;
        return -1;
    }
    return 0;
}

static int supervise(void) {
    struct sigaction sa; memset(&sa, 0, sizeof sa); sa.sa_handler = sv_on;
    sigaction(SIGUSR1, &sa, NULL); sigaction(SIGUSR2, &sa, NULL); sigaction(SIGHUP, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL); sigaction(SIGINT, &sa, NULL);
    double backoff = 100;
    for (;;) {
        double started = now_ms();
        pid_t w = fork();
        if (w == 0) {
            struct sigaction d; memset(&d, 0, sizeof d); d.sa_handler = SIG_DFL;
            sigaction(SIGUSR1, &d, NULL); sigaction(SIGUSR2, &d, NULL); sigaction(SIGHUP, &d, NULL); sigaction(SIGTERM, &d, NULL); sigaction(SIGINT, &d, NULL);
            _exit(worker_main());
        }
        if (w < 0) { logm("supervisor: fork: %s", strerror(errno)); sleep(1); continue; }
        logm("supervisor %d: worker %d started (generation %llu)", (int)getpid(), (int)w, (unsigned long long)wgen);
        int status = 0;
        for (;;) {
            pid_t r = waitpid(w, &status, 0);
            if (r == w) break;
            if (r < 0 && errno != EINTR) break;
            int s = sv_sig; sv_sig = 0;
            if (s == SIGUSR1 || s == SIGHUP || s == SIGUSR2) kill(w, s);
            else if (s == SIGTERM || s == SIGINT) {
                logm("supervisor: SIGTERM — stopping the view at %s", mnt_path);
                kill(w, SIGTERM); waitpid(w, NULL, 0);
                umount2(mnt_path, MNT_DETACH);
                if (pid_path) unlink(pid_path);
                return 0;
            }
        }
        int code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
        if (WIFSIGNALED(status)) logm("supervisor: worker %d killed by signal %d — restarting", (int)w, WTERMSIG(status));
        else logm("supervisor: worker %d exited %d — restarting", (int)w, code);
        if (code == 3) { /* the connection is gone (someone unmounted the view): mount a fresh one */
            close(fusefd); fusefd = -1;
            umount2(mnt_path, MNT_DETACH);
            while (do_mount() != 0) { logm("supervisor: re-mount failed — retrying in 1 s"); sleep(1); if (sv_sig == SIGTERM) return 0; }
            logm("supervisor: mounted a fresh view at %s", mnt_path);
        }
        if (now_ms() - started > 60000) backoff = 100;
        struct timespec ts = {(time_t)(backoff / 1000), (long)((long)backoff % 1000) * 1000000L};
        nanosleep(&ts, NULL);
        backoff = backoff * 2 > 5000 ? 5000 : backoff * 2;
        wgen = (wgen % 0xfffe) + 1; restarts++;
        if (sv_sig == SIGTERM || sv_sig == SIGINT) { umount2(mnt_path, MNT_DETACH); if (pid_path) unlink(pid_path); return 0; }
    }
}

static int start(void) {
    if (!raw_path || !mnt_path || !conf_path || !pid_path) { fprintf(stderr, "dozview start: --raw, --mount, --conf and --pidfile are required\n"); return 2; }
    int probe = open(raw_path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (probe < 0) { fprintf(stderr, "dozview: %s: %s\n", raw_path, strerror(errno)); return 1; }
    if (!is_share(probe)) { fprintf(stderr, "dozview: %s is not a virtio-fs share\n", raw_path); close(probe); return 1; }
    close(probe);
    if (do_mount() != 0) return 1;
    int ready[2]; if (pipe(ready)) { perror("pipe"); return 1; }
    pid_t p = fork();
    if (p < 0) { perror("fork"); return 1; }
    if (p > 0) {
        close(ready[1]);
        char b; (void)!read(ready[0], &b, 1);
        printf("%d\n", (int)p);
        return 0;
    }
    close(ready[0]);
    setsid();
    int nul = open("/dev/null", O_RDWR);
    if (nul >= 0) { dup2(nul, 0); dup2(nul, 1); dup2(nul, 2); if (nul > 2) close(nul); }
    FILE *pf = fopen(pid_path, "we");
    if (pf) { fprintf(pf, "%d\n", (int)getpid()); fclose(pf); }
    logm("dozview %s: supervisor %d — the view of %s is mounted at %s", DOZVIEW_VERSION, (int)getpid(), raw_path, mnt_path);
    (void)!write(ready[1], "r", 1); close(ready[1]);
    return supervise();
}

int main(int argc, char **argv) {
    if (argc >= 2 && !strcmp(argv[1], "version")) { printf("dozview %s\n", DOZVIEW_VERSION); return 0; }
    if (argc < 2 || strcmp(argv[1], "start")) {
        fprintf(stderr, "usage: dozview start --raw RAW --mount MNT --conf CONF --pidfile PID [--state STATE] [--log LOG] [--threads N] [--timeout S]\n"
                        "       dozview version\n");
        return 2;
    }
    for (int i = 2; i < argc; i += 2) {
        const char *a = argv[i], *v = i + 1 < argc ? argv[i + 1] : NULL;
        if (!v) { fprintf(stderr, "dozview: %s needs a value\n", a); return 2; }
        if (!strcmp(a, "--raw")) raw_path = v;
        else if (!strcmp(a, "--mount")) mnt_path = v;
        else if (!strcmp(a, "--conf")) conf_path = v;
        else if (!strcmp(a, "--state")) state_path = v;
        else if (!strcmp(a, "--pidfile")) pid_path = v;
        else if (!strcmp(a, "--log")) log_path = v;
        else if (!strcmp(a, "--threads")) { nthreads = atoi(v); if (nthreads < 1 || nthreads > 64) nthreads = 6; }
        else if (!strcmp(a, "--timeout")) { tmo = atof(v); if (tmo < 0 || tmo > 3600) tmo = 1.0; }
        else { fprintf(stderr, "dozview: unknown option %s\n", a); return 2; }
    }
    return start();
}
