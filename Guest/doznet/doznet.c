/*
 * doznet — the guest half of a proxied sandbox's network (feature 580). MIT, this package.
 *
 * A proxied sandbox's VM has NO network interface: only `lo`. This small static binary is the
 * guest's only way out, and it enforces nothing — every decision is made by the host proxy
 * (EgressProxy, in the app process), which the guest cannot reach except through vsock:
 *
 *   127.0.0.1:3128/tcp  HTTP proxy port    one vsock stream to the host per connection:
 *                                          "DOZ1 P\n", then the client's bytes as they are.
 *                                          HTTP(S)_PROXY point here.
 *   127.0.0.1:3129/tcp  transparent TCP     every other outbound TCP connection lands here (the
 *                                          nat OUTPUT REDIRECT below); the original destination
 *                                          (SO_ORIGINAL_DST) goes first: "DOZ1 T a.b.c.d PORT\n".
 *   127.0.0.1:53/udp    DNS                one vsock stream per query: "DOZ1 D\n" <u16 len><query>;
 *                                          the host answers <u16 len><reply>. resolv.conf → here.
 *
 * `doznet up` (as root) also makes that redirect possible and blocks UDP:
 *   - a default route via `lo` (only `lo` exists; without a route a connect() fails with
 *     ENETUNREACH before netfilter sees it) and a /32 source address on it (169.254.255.254,
 *     label lo:doz — without it outbound sockets get source 0.0.0.0 and stall after the SYN);
 *   - iptables (legacy, via setsockopt — no iptables binary needed in the image):
 *       nat    OUTPUT  -p tcp ! -d 127.0.0.0/8 -j REDIRECT --to-ports 3129
 *       filter OUTPUT  -p udp ! -d 127.0.0.0/8 -j REJECT  (icmp-port-unreachable: QUIC and outside
 *                                                           DNS fail fast, clients fall back to TCP)
 *   Root in the guest can undo all of this; that only removes its own way out, because no route
 *   leaves the VM except the vsock to a host that applies the policy.
 *
 * Every connection is dialled afresh, so after a sleep to disk → wake (which severs every vsock
 * stream) the next connection simply works.
 *
 * 599d (G4): `doznet agent` — the guest half of the user's forwarded SSH agent (only while the user
 * turned it on): a unix socket whose every connection is relayed, bytes as they are, over vsock to the
 * host (CID 2, port 5801), which connects it to the Mac's ssh-agent. The keys never enter the guest; the
 * guest can only ask the agent to sign. It decides nothing either.
 *
 * Usage:  doznet up [-p VSOCK_PORT] [--no-firewall]    daemonizes once listening
 *         doznet status                                 prints the pid, or exits 1
 *         doznet agent [-p VSOCK_PORT] -s SOCKET        daemonizes once listening (599d)
 *         doznet agent status | doznet agent stop
 * Build:  Guest/doznet/build.sh (pinned Zig; see PROVENANCE.md)
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <net/if.h>
#include <net/route.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#include <linux/netfilter_ipv4.h>
#include <linux/netfilter_ipv4/ip_tables.h>
#include <linux/netfilter_ipv4/ipt_REJECT.h>
#include <linux/netfilter/nf_nat.h>
#include <linux/vm_sockets.h>

#define PROXY_PORT 3128
#define TRANSPARENT_PORT 3129
#define PIDFILE "/run/doznet.pid"
#define LOGFILE "/run/doznet.log"

static unsigned g_vport = 5800;
static FILE *g_log;
static pthread_mutex_t g_log_lock = PTHREAD_MUTEX_INITIALIZER;

static void logf_(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void logf_(const char *fmt, ...) {
    if (!g_log) return;
    pthread_mutex_lock(&g_log_lock);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(g_log, fmt, ap);
    va_end(ap);
    fputc('\n', g_log);
    fflush(g_log);
    pthread_mutex_unlock(&g_log_lock);
}

/* ── vsock + byte plumbing ─────────────────────────────────────────────────────────────────── */

static int dial_host(void) {
    int fd = socket(AF_VSOCK, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return -1;
    struct sockaddr_vm a = { .svm_family = AF_VSOCK, .svm_cid = VMADDR_CID_HOST, .svm_port = g_vport };
    if (connect(fd, (struct sockaddr *)&a, sizeof a) != 0) { int e = errno; close(fd); errno = e; return -1; }
    return fd;
}

static int write_all(int fd, const void *p, size_t n) {
    const char *b = p;
    while (n) {
        ssize_t w = write(fd, b, n);
        if (w < 0) { if (errno == EINTR) continue; return -1; }
        b += w; n -= (size_t)w;
    }
    return 0;
}

static int read_all(int fd, void *p, size_t n) {
    char *b = p;
    while (n) {
        ssize_t r = read(fd, b, n);
        if (r < 0) { if (errno == EINTR) continue; return -1; }
        if (r == 0) return -1;
        b += r; n -= (size_t)r;
    }
    return 0;
}

/* Copy both ways until both directions are closed; a half-close is passed on as shutdown(). */
static void relay(int a, int b) {
    char *buf = malloc(65536);
    if (!buf) return;
    int a_open = 1, b_open = 1;
    while (a_open || b_open) {
        struct pollfd p[2] = { { a_open ? a : -1, POLLIN, 0 }, { b_open ? b : -1, POLLIN, 0 } };
        if (poll(p, 2, -1) < 0) { if (errno == EINTR) continue; break; }
        for (int i = 0; i < 2; i++) {
            if (!p[i].revents) continue;
            int from = i ? b : a, to = i ? a : b;
            ssize_t r = read(from, buf, 65536);
            if (r < 0 && errno == EINTR) continue;
            if (r <= 0) {
                shutdown(to, SHUT_WR);
                if (i) b_open = 0; else a_open = 0;
                if (r < 0) goto done;
                continue;
            }
            if (write_all(to, buf, (size_t)r) != 0) goto done;
        }
    }
done:
    free(buf);
}

static void spawn(void *(*fn)(void *), void *arg) {
    pthread_t t;
    pthread_attr_t at;
    pthread_attr_init(&at);
    pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
    pthread_attr_setstacksize(&at, 128 * 1024);
    if (pthread_create(&t, &at, fn, arg) != 0) { logf_("pthread_create failed"); }
    pthread_attr_destroy(&at);
}

/* ── the three listeners ───────────────────────────────────────────────────────────────────── */

struct conn { int fd; int transparent; };

static void *tcp_conn(void *arg) {
    struct conn *c = arg;
    char header[96] = "DOZ1 P\n";
    if (c->transparent) {
        struct sockaddr_in dst;
        socklen_t dl = sizeof dst;
        if (getsockopt(c->fd, SOL_IP, SO_ORIGINAL_DST, &dst, &dl) != 0) {
            logf_("transparent: no original destination: %s", strerror(errno));
            close(c->fd); free(c); return NULL;
        }
        char ip[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &dst.sin_addr, ip, sizeof ip);
        snprintf(header, sizeof header, "DOZ1 T %s %u\n", ip, ntohs(dst.sin_port));
    }
    int h = dial_host();
    if (h < 0) {
        logf_("vsock dial failed: %s", strerror(errno));
        close(c->fd); free(c); return NULL;
    }
    if (write_all(h, header, strlen(header)) == 0) relay(c->fd, h);
    close(h);
    close(c->fd);
    free(c);
    return NULL;
}

struct dnsq { int ufd; struct sockaddr_in from; unsigned char q[1500]; size_t n; };

static void *dns_query(void *arg) {
    struct dnsq *d = arg;
    int h = dial_host();
    if (h < 0) { logf_("dns: vsock dial failed: %s", strerror(errno)); free(d); return NULL; }
    struct timeval tv = { .tv_sec = 10 };
    setsockopt(h, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    unsigned char len[2] = { (unsigned char)(d->n >> 8), (unsigned char)d->n };
    unsigned char *rep = malloc(65536);
    if (rep && write_all(h, "DOZ1 D\n", 7) == 0 && write_all(h, len, 2) == 0 && write_all(h, d->q, d->n) == 0
        && read_all(h, len, 2) == 0) {
        size_t rn = ((size_t)len[0] << 8) | len[1];
        if (read_all(h, rep, rn) == 0)
            sendto(d->ufd, rep, rn, 0, (struct sockaddr *)&d->from, sizeof d->from);
    }
    free(rep);
    close(h);
    free(d);
    return NULL;
}

static int listen_on(int type, unsigned port) {
    int fd = socket(AF_INET, type | SOCK_CLOEXEC, 0);
    if (fd < 0) return -1;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons(port), .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
    if (bind(fd, (struct sockaddr *)&a, sizeof a) != 0 || (type == SOCK_STREAM && listen(fd, 256) != 0)) {
        int e = errno; close(fd); errno = e;
        return -1;
    }
    return fd;
}

/* ── lo, the route, the firewall ───────────────────────────────────────────────────────────── */

static void lo_up(void) {
    int s = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    struct ifreq r;
    memset(&r, 0, sizeof r);
    strcpy(r.ifr_name, "lo");
    if (s >= 0 && ioctl(s, SIOCGIFFLAGS, &r) == 0 && !(r.ifr_flags & IFF_UP)) {
        r.ifr_flags |= IFF_UP | IFF_RUNNING;
        ioctl(s, SIOCSIFFLAGS, &r);
    }
    if (s >= 0) close(s);
}

/* A global-scope /32 on lo ("lo:doz"). lo's own 127.0.0.1 is host-scoped, so without this an
 * outbound socket to a public address gets the source 0.0.0.0: its SYN is still redirected, but
 * every later segment is dropped (580.03). The alias is only ever a source address; it routes nowhere. */
#define SOURCE_ADDRESS "169.254.255.254"
static int lo_source_alias(void) {
    int s = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (s < 0) return -1;
    struct ifreq r;
    memset(&r, 0, sizeof r);
    strcpy(r.ifr_name, "lo:doz");
    struct sockaddr_in *a = (struct sockaddr_in *)&r.ifr_addr;
    a->sin_family = AF_INET;
    inet_pton(AF_INET, SOURCE_ADDRESS, &a->sin_addr);
    int rc = ioctl(s, SIOCSIFADDR, &r);
    if (rc == 0) {
        inet_pton(AF_INET, "255.255.255.255", &((struct sockaddr_in *)&r.ifr_netmask)->sin_addr);
        r.ifr_netmask.sa_family = AF_INET;
        rc = ioctl(s, SIOCSIFNETMASK, &r);
    }
    int e = errno;
    close(s);
    errno = e;
    return rc;
}

/* default dev lo: gives outbound connects a route, so netfilter's OUTPUT hook sees them. */
static int default_route_via_lo(void) {
    int s = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (s < 0) return -1;
    struct rtentry rt;
    memset(&rt, 0, sizeof rt);
    struct sockaddr_in *dst = (struct sockaddr_in *)&rt.rt_dst, *mask = (struct sockaddr_in *)&rt.rt_genmask;
    dst->sin_family = AF_INET;
    mask->sin_family = AF_INET;
    rt.rt_flags = RTF_UP;
    rt.rt_dev = "lo";
    int r = ioctl(s, SIOCADDRT, &rt);
    int e = errno;
    close(s);
    if (r != 0 && e != EEXIST) { errno = e; return -1; }
    return 0;
}

#define ALIGNED(x) XT_ALIGN(x)

struct blob { unsigned char *p; size_t n, cap; };

static void *blob_add(struct blob *b, size_t n) {
    if (b->n + n > b->cap) {
        b->cap = (b->n + n) * 2;
        b->p = realloc(b->p, b->cap);
    }
    void *at = b->p + b->n;
    memset(at, 0, n);
    b->n += n;
    return at;
}

/* An entry that matches everything and ACCEPTs (a chain policy). */
static size_t add_policy(struct blob *b) {
    size_t off = b->n;
    size_t tsz = ALIGNED(sizeof(struct xt_standard_target));
    struct ipt_entry *e = blob_add(b, sizeof(struct ipt_entry) + tsz);
    e->target_offset = sizeof(struct ipt_entry);
    e->next_offset = (uint16_t)(sizeof(struct ipt_entry) + tsz);
    struct xt_standard_target *t = (void *)((unsigned char *)e + e->target_offset);
    t->target.u.target_size = (uint16_t)tsz;
    t->verdict = -NF_ACCEPT - 1;
    return off;
}

static size_t add_error(struct blob *b) {
    size_t off = b->n;
    size_t tsz = ALIGNED(sizeof(struct xt_error_target));
    struct ipt_entry *e = blob_add(b, sizeof(struct ipt_entry) + tsz);
    e->target_offset = sizeof(struct ipt_entry);
    e->next_offset = (uint16_t)(sizeof(struct ipt_entry) + tsz);
    struct xt_error_target *t = (void *)((unsigned char *)e + e->target_offset);
    t->target.u.user.target_size = (uint16_t)tsz;
    strcpy(t->target.u.user.name, XT_ERROR_TARGET);
    strcpy(t->errorname, "ERROR");
    return off;
}

/* `-p PROTO ! -d 127.0.0.0/8 -j NAME` with `data` as the target's payload. */
static size_t add_rule(struct blob *b, uint16_t proto, const char *name, const void *data, size_t dlen) {
    size_t off = b->n;
    size_t tsz = ALIGNED(sizeof(struct xt_entry_target) + dlen);
    struct ipt_entry *e = blob_add(b, sizeof(struct ipt_entry) + tsz);
    e->ip.proto = proto;
    e->ip.dst.s_addr = htonl(0x7F000000);
    e->ip.dmsk.s_addr = htonl(0xFF000000);
    e->ip.invflags = IPT_INV_DSTIP;
    e->target_offset = sizeof(struct ipt_entry);
    e->next_offset = (uint16_t)(sizeof(struct ipt_entry) + tsz);
    struct xt_entry_target *t = (void *)((unsigned char *)e + e->target_offset);
    t->u.user.target_size = (uint16_t)tsz;
    strcpy(t->u.user.name, name);
    memcpy(t->data, data, dlen);
    return off;
}

static int replace_table(int s, const char *table, struct blob *entries, unsigned n_entries,
                         const size_t hook[NF_INET_NUMHOOKS], const size_t under[NF_INET_NUMHOOKS]) {
    struct ipt_getinfo info;
    memset(&info, 0, sizeof info);
    strcpy(info.name, table);
    socklen_t il = sizeof info;
    if (getsockopt(s, IPPROTO_IP, IPT_SO_GET_INFO, &info, &il) != 0) return -1;
    size_t rs = sizeof(struct ipt_replace) + entries->n;
    struct ipt_replace *r = calloc(1, rs);
    struct xt_counters *counters = calloc(info.num_entries ? info.num_entries : 1, sizeof *counters);
    if (!r || !counters) { free(r); free(counters); errno = ENOMEM; return -1; }
    strcpy(r->name, table);
    r->valid_hooks = info.valid_hooks;
    r->num_entries = n_entries;
    r->size = (unsigned)entries->n;
    for (int h = 0; h < NF_INET_NUMHOOKS; h++) {
        r->hook_entry[h] = (unsigned)hook[h];
        r->underflow[h] = (unsigned)under[h];
    }
    r->num_counters = info.num_entries;
    r->counters = counters;
    memcpy(r->entries, entries->p, entries->n);
    int rc = setsockopt(s, IPPROTO_IP, IPT_SO_SET_REPLACE, r, (socklen_t)rs);
    int e = errno;
    free(r); free(counters);
    errno = e;
    return rc;
}

static int firewall(void) {
    int s = socket(AF_INET, SOCK_RAW | SOCK_CLOEXEC, IPPROTO_RAW);
    if (s < 0) { logf_("firewall: raw socket: %s", strerror(errno)); return -1; }
    int ok = 0;

    /* nat: PREROUTING, INPUT, OUTPUT (+ the REDIRECT rule), POSTROUTING. */
    {
        struct blob b = { 0 };
        size_t hook[NF_INET_NUMHOOKS] = { 0 }, under[NF_INET_NUMHOOKS] = { 0 };
        hook[NF_INET_PRE_ROUTING] = under[NF_INET_PRE_ROUTING] = add_policy(&b);
        hook[NF_INET_LOCAL_IN] = under[NF_INET_LOCAL_IN] = add_policy(&b);
        struct nf_nat_ipv4_multi_range_compat redirect;
        memset(&redirect, 0, sizeof redirect);
        redirect.rangesize = 1;
        redirect.range[0].flags = NF_NAT_RANGE_PROTO_SPECIFIED;
        redirect.range[0].min.tcp.port = redirect.range[0].max.tcp.port = htons(TRANSPARENT_PORT);
        hook[NF_INET_LOCAL_OUT] = add_rule(&b, IPPROTO_TCP, "REDIRECT", &redirect, sizeof redirect);
        under[NF_INET_LOCAL_OUT] = add_policy(&b);
        hook[NF_INET_POST_ROUTING] = under[NF_INET_POST_ROUTING] = add_policy(&b);
        add_error(&b);
        if (replace_table(s, "nat", &b, 6, hook, under) != 0) {
            logf_("firewall: nat table: %s", strerror(errno)); ok = -1;
        }
        free(b.p);
    }
    /* filter: INPUT, FORWARD, OUTPUT (+ REJECT udp). */
    {
        struct blob b = { 0 };
        size_t hook[NF_INET_NUMHOOKS] = { 0 }, under[NF_INET_NUMHOOKS] = { 0 };
        hook[NF_INET_LOCAL_IN] = under[NF_INET_LOCAL_IN] = add_policy(&b);
        hook[NF_INET_FORWARD] = under[NF_INET_FORWARD] = add_policy(&b);
        struct ipt_reject_info rej = { .with = IPT_ICMP_PORT_UNREACHABLE };
        hook[NF_INET_LOCAL_OUT] = add_rule(&b, IPPROTO_UDP, "REJECT", &rej, sizeof rej);
        under[NF_INET_LOCAL_OUT] = add_policy(&b);
        add_error(&b);
        if (replace_table(s, "filter", &b, 5, hook, under) != 0) {
            logf_("firewall: filter table: %s", strerror(errno)); ok = -1;
        }
        free(b.p);
    }
    close(s);
    return ok;
}

/* ── main ──────────────────────────────────────────────────────────────────────────────────── */

static int running_pid(const char *pidfile) {
    FILE *f = fopen(pidfile, "r");
    int pid = 0;
    if (f) { if (fscanf(f, "%d", &pid) != 1) pid = 0; fclose(f); }
    return pid > 0 && kill(pid, 0) == 0 ? pid : 0;
}

static int status(void) {
    int pid = running_pid(PIDFILE);
    if (pid) { printf("%d\n", pid); return 0; }
    return 1;
}

/* ── 599d: the forwarded SSH agent ─────────────────────────────────────────────────────────── */

#define AGENT_PIDFILE "/run/doznet-agent.pid"

static void *agent_conn(void *arg) {
    int c = (int)(intptr_t)arg;
    int h = dial_host();
    if (h < 0) { logf_("agent: vsock dial failed: %s", strerror(errno)); close(c); return NULL; }
    relay(c, h);
    close(h);
    close(c);
    return NULL;
}

static int agent_main(int argc, char **argv) {
    if (argc >= 3 && !strcmp(argv[2], "status")) {
        int pid = running_pid(AGENT_PIDFILE);
        if (pid) { printf("%d\n", pid); return 0; }
        return 1;
    }
    if (argc >= 3 && !strcmp(argv[2], "stop")) {
        int pid = running_pid(AGENT_PIDFILE);
        if (pid) kill(pid, SIGTERM);
        unlink(AGENT_PIDFILE);
        return 0;
    }
    const char *path = NULL;
    g_vport = 5801;
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "-p") && i + 1 < argc) g_vport = (unsigned)atoi(argv[++i]);
        else if (!strcmp(argv[i], "-s") && i + 1 < argc) path = argv[++i];
    }
    struct sockaddr_un a = { .sun_family = AF_UNIX };
    if (!path || path[0] != '/' || strlen(path) >= sizeof a.sun_path) {
        fprintf(stderr, "usage: doznet agent [-p VSOCK_PORT] -s /absolute/socket | doznet agent status | doznet agent stop\n");
        return 2;
    }
    if (running_pid(AGENT_PIDFILE)) { printf("doznet agent: already running\n"); return 0; }
    signal(SIGPIPE, SIG_IGN);
    mkdir("/run", 0755);
    g_log = fopen(LOGFILE, "a");
    char dir[sizeof a.sun_path];
    snprintf(dir, sizeof dir, "%s", path);
    char *slash = strrchr(dir, '/');
    if (slash && slash != dir) { *slash = 0; mkdir(dir, 0755); }
    strcpy(a.sun_path, path);
    unlink(path);
    int s = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (s < 0 || bind(s, (struct sockaddr *)&a, sizeof a) != 0 || listen(s, 64) != 0) {
        fprintf(stderr, "doznet agent: listen on %s: %s\n", path, strerror(errno));
        return 1;
    }
    chmod(path, 0666);              /* every user of the sandbox — the agent is the sandbox's to use */
    pid_t p = fork();
    if (p < 0) { perror("fork"); return 1; }
    if (p > 0) {
        FILE *f = fopen(AGENT_PIDFILE, "w");
        if (f) { fprintf(f, "%d\n", p); fclose(f); }
        printf("doznet agent: %s → vsock %u\n", path, g_vport);
        return 0;
    }
    setsid();
    int dn = open("/dev/null", O_RDWR);
    dup2(dn, 0); dup2(dn, 1); dup2(dn, 2);
    if (dn > 2) close(dn);
    logf_("agent: %s → vsock port %u", path, g_vport);
    for (;;) {
        int c = accept4(s, NULL, NULL, SOCK_CLOEXEC);
        if (c < 0) { if (errno == EINTR) continue; logf_("agent: accept: %s", strerror(errno)); sleep(1); continue; }
        spawn(agent_conn, (void *)(intptr_t)c);
    }
}

int main(int argc, char **argv) {
    if (argc >= 2 && !strcmp(argv[1], "status")) return status();
    if (argc >= 2 && !strcmp(argv[1], "agent")) return agent_main(argc, argv);
    if (argc < 2 || strcmp(argv[1], "up") != 0) {
        fprintf(stderr, "usage: doznet up [-p VSOCK_PORT] [--no-firewall] | doznet status\n");
        return 2;
    }
    int fw = 1;
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "-p") && i + 1 < argc) g_vport = (unsigned)atoi(argv[++i]);
        else if (!strcmp(argv[i], "--no-firewall")) fw = 0;
    }
    if (status() == 0) { printf("doznet: already running\n"); return 0; }
    signal(SIGPIPE, SIG_IGN);
    mkdir("/run", 0755);
    g_log = fopen(LOGFILE, "a");
    lo_up();
    int proxy = listen_on(SOCK_STREAM, PROXY_PORT);
    int transparent = listen_on(SOCK_STREAM, TRANSPARENT_PORT);
    int dns = listen_on(SOCK_DGRAM, 53);
    if (proxy < 0 || transparent < 0 || dns < 0) { perror("doznet: listen on 127.0.0.1"); return 1; }
    const char *fwnote = "firewall off";
    if (fw) {
        if (lo_source_alias() != 0) { fprintf(stderr, "doznet: source address on lo: %s\n", strerror(errno)); return 1; }
        if (default_route_via_lo() != 0) { fprintf(stderr, "doznet: default route via lo: %s\n", strerror(errno)); return 1; }
        if (firewall() != 0) { fprintf(stderr, "doznet: firewall setup failed (see %s)\n", LOGFILE); return 1; }
        fwnote = "tcp → 3129, udp rejected";
    }
    pid_t p = fork();
    if (p < 0) { perror("fork"); return 1; }
    if (p > 0) {
        FILE *f = fopen(PIDFILE, "w");
        if (f) { fprintf(f, "%d\n", p); fclose(f); }
        printf("doznet: up (proxy 127.0.0.1:%d, transparent :%d, dns :53; %s) → vsock %u\n",
               PROXY_PORT, TRANSPARENT_PORT, fwnote, g_vport);
        return 0;
    }
    setsid();
    int dn = open("/dev/null", O_RDWR);
    dup2(dn, 0); dup2(dn, 1); dup2(dn, 2);
    if (dn > 2) close(dn);
    logf_("up: vsock port %u (%s)", g_vport, fwnote);
    for (;;) {
        struct pollfd pf[3] = { { proxy, POLLIN, 0 }, { transparent, POLLIN, 0 }, { dns, POLLIN, 0 } };
        if (poll(pf, 3, -1) < 0) continue;
        for (int i = 0; i < 2; i++) {
            if (!pf[i].revents) continue;
            int c = accept4(i ? transparent : proxy, NULL, NULL, SOCK_CLOEXEC);
            if (c < 0) continue;
            struct conn *cc = malloc(sizeof *cc);
            if (!cc) { close(c); continue; }
            cc->fd = c; cc->transparent = i;
            spawn(tcp_conn, cc);
        }
        if (pf[2].revents) {
            struct dnsq *d = calloc(1, sizeof *d);
            if (!d) continue;
            socklen_t fl = sizeof d->from;
            ssize_t n = recvfrom(dns, d->q, sizeof d->q, 0, (struct sockaddr *)&d->from, &fl);
            if (n <= 0) { free(d); continue; }
            d->n = (size_t)n; d->ufd = dns;
            spawn(dns_query, d);
        }
    }
}
