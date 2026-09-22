/* NNG (mbedTLS) footprint probe, throwaway measurement. Server: probe server PORT CERTDIR ; client: probe client PORT CERTDIR CHURN
   Ports: PORT rep, PORT+1 pull, PORT+2 pair(poly). */
#include <nng/nng.h>
#include <nng/protocol/reqrep0/req.h>
#include <nng/protocol/reqrep0/rep.h>
#include <nng/protocol/pipeline0/push.h>
#include <nng/protocol/pipeline0/pull.h>
#include <nng/protocol/pair1/pair.h>
#include <nng/supplemental/tls/tls.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
static double MiB = 1048576.0;
static long rss(void) { long a, b = 0; FILE *f = fopen("/proc/self/statm", "r"); if (fscanf(f, "%ld %ld", &a, &b) != 2) b = 0; fclose(f); return b * 4096; }
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
static const char *dir;
static char *slurp(const char *n) { char p[300]; snprintf(p, sizeof p, "%s/%s", dir, n); FILE *f = fopen(p, "rb"); fseek(f, 0, SEEK_END); long z = ftell(f); rewind(f);
  char *b = calloc(1, z + 1); if (fread(b, 1, z, f) != (size_t)z) exit(2); fclose(f); return b; }
static nng_tls_config *mkcfg(int server, const char *cert, const char *ca, const char *hostname) {
  nng_tls_config *c; nng_tls_config_alloc(&c, server ? NNG_TLS_MODE_SERVER : NNG_TLS_MODE_CLIENT);
  char n1[64], n2[64]; char *cab = slurp(ca); nng_tls_config_ca_chain(c, cab, NULL); free(cab);
  if (cert) { snprintf(n1, sizeof n1, "%s.pem", cert); snprintf(n2, sizeof n2, "%s.key", cert); char *cb = slurp(n1), *kb = slurp(n2); nng_tls_config_own_cert(c, cb, kb, NULL); free(cb); free(kb); }
  nng_tls_config_auth_mode(c, NNG_TLS_AUTH_MODE_REQUIRED);
  if (hostname) nng_tls_config_server_name(c, hostname);
  return c; }
static int listen_tls(nng_socket s, int port, nng_tls_config *cfg) { char u[64]; snprintf(u, sizeof u, "tls+tcp://127.0.0.1:%d", port);
  nng_listener l; int r = nng_listener_create(&l, s, u); if (r) return r; nng_listener_set_ptr(l, NNG_OPT_TLS_CONFIG, cfg); return nng_listener_start(l, 0); }
static int dial_tls(nng_socket s, int port, nng_tls_config *cfg) { char u[64]; snprintf(u, sizeof u, "tls+tcp://localhost:%d", port);
  nng_dialer d; int r = nng_dialer_create(&d, s, u); if (r) return r; nng_dialer_set_ptr(d, NNG_OPT_TLS_CONFIG, cfg); return nng_dialer_start(d, 0); }
/* ---- server ---- */
static nng_socket rep, pull, pair; static long pulled;
static void *t_rep(void *a) { for (;;) { char *b; size_t n; if (nng_recv(rep, &b, &n, NNG_FLAG_ALLOC)) continue; char out[64]; int m;
    if (n == 1 && b[0] == 'R') m = snprintf(out, sizeof out, "%ld", rss()); else if (n == 1 && b[0] == 'S') m = snprintf(out, sizeof out, "%ld", pulled); else { memcpy(out, b, n < 64 ? n : 64); m = n < 64 ? n : 64; }
    nng_free(b, n); nng_send(rep, out, m, 0); } return NULL; }
static void *t_pull(void *a) { for (;;) { char *b; size_t n; if (nng_recv(pull, &b, &n, NNG_FLAG_ALLOC)) continue; pulled += n; nng_free(b, n); } return NULL; }
static void *t_pair(void *a) { for (;;) { nng_msg *m; if (nng_recvmsg(pair, &m, 0)) continue; nng_sendmsg(pair, m, 0); } return NULL; }
static int server(int port) {
  nng_rep0_open(&rep); nng_pull0_open(&pull); nng_pair1_open_poly(&pair);
  nng_socket_set_ms(pull, NNG_OPT_RECVBUF, 8); /* bounded receive queue */
  int r1 = listen_tls(rep, port, mkcfg(1, "server", "ca.pem", NULL)), r2 = listen_tls(pull, port + 1, mkcfg(1, "server", "ca.pem", NULL)), r3 = listen_tls(pair, port + 2, mkcfg(1, "server", "ca.pem", NULL));
  printf("server listening (%d %d %d), RSS %.1f MiB\n", r1, r2, r3, rss() / MiB); fflush(stdout);
  pthread_t t; pthread_create(&t, NULL, t_rep, NULL); pthread_create(&t, NULL, t_pull, NULL); pthread_create(&t, NULL, t_pair, NULL); for (;;) nng_msleep(1000); }
/* ---- client ---- */
static int req_once(nng_socket s, const char *m, size_t n, char *out, size_t *on) { int r = nng_send(s, (void *)m, n, 0); if (r) return r; char *b; size_t bn; r = nng_recv(s, &b, &bn, NNG_FLAG_ALLOC); if (r) return r;
  if (out) { memcpy(out, b, bn < *on ? bn : *on); *on = bn; } nng_free(b, bn); return 0; }
static long server_rss(nng_socket s) { char o[64] = {0}; size_t n = 63; if (req_once(s, "R", 1, o, &n)) return -1; return atol(o); }
static int port; static nng_socket psock; static void *burst_sender(void *a) { char m[16]; for (int i = 0; i < 2000; i++) { int n = snprintf(m, sizeof m, "b%d", i); nng_send(psock, m, n, 0); } return NULL; }
static int client(int p, int churn) {
  port = p; printf("process start:                       %.1f MiB\n", rss() / MiB);
  nng_socket s; nng_req0_open(&s); nng_socket_set_ms(s, NNG_OPT_RECVTIMEO, 3000); nng_socket_set_ms(s, NNG_OPT_SENDTIMEO, 3000);
  int r = dial_tls(s, p, mkcfg(0, "client", "ca.pem", "localhost")); char o[64]; size_t on = 63; int q = req_once(s, "hi", 2, o, &on);
  printf("after mTLS connect + 1 request (dial %d, req %d): %.1f MiB\n", r, q, rss() / MiB);
  struct { const char *label, *cert, *ca; } bad[] = {{"no client cert", NULL, "ca.pem"}, {"foreign-CA client cert", "rogue", "ca.pem"}, {"untrusted server", "client", "rogue-ca.pem"}};
  for (int i = 0; i < 3; i++) { nng_socket b; nng_req0_open(&b); nng_socket_set_ms(b, NNG_OPT_RECVTIMEO, 2000); nng_socket_set_ms(b, NNG_OPT_SENDTIMEO, 2000);
    int d = dial_tls(b, p, mkcfg(0, bad[i].cert, bad[i].ca, "localhost")); size_t bn = 63; char bo[64]; int rq = d ? d : req_once(b, "x", 1, bo, &bn);
    printf("%-24s %s (%s)\n", bad[i].label, rq ? "rejected" : "ACCEPTED (bad)", nng_strerror(rq)); nng_close(b); }
  /* request/reply ping-pong */
  int ok = 0; double t0 = now(); for (int i = 0; i < 2000; i++) { char m[32], x[32]; size_t xn = 31; int n = snprintf(m, sizeof m, "m%d", i); if (!req_once(s, m, n, x, &xn) && xn == (size_t)n && !memcmp(m, x, n)) ok++; }
  printf("request/reply: %d/2000 correct, %.0f req/s\n", ok, 2000 / (now() - t0));
  /* push 256 MiB */
  nng_socket ps; nng_push0_open(&ps); nng_socket_set_ms(ps, NNG_OPT_SENDTIMEO, 10000); dial_tls(ps, p + 1, mkcfg(0, "client", "ca.pem", "localhost"));
  static char chunk[65536]; memset(chunk, 'x', sizeof chunk); long r0 = rss(), rmax = r0; t0 = now(); int sent = 0;
  for (int i = 0; i < 4096; i++) { if (nng_send(ps, chunk, sizeof chunk, 0) == 0) sent++; if (i % 256 == 0 && rss() > rmax) rmax = rss(); }
  double dt = now() - t0; nng_msleep(500); char so[64] = {0}; size_t sn = 63; req_once(s, "S", 1, so, &sn);
  printf("push 256 MiB: sent %d/4096, server received %.0f MiB, %.0f MiB/s, client RSS growth %.1f MiB\n", sent, atol(so) / MiB, sent * 64.0 / 1024 / dt, (rmax - r0) / MiB);
  /* pair (poly): 100 ping-pong then 2000-message burst while reading = full duplex */
  nng_pair1_open_poly(&psock); nng_socket_set_ms(psock, NNG_OPT_RECVTIMEO, 3000); dial_tls(psock, p + 2, mkcfg(0, "client", "ca.pem", "localhost"));
  int pp = 0; for (int i = 0; i < 100; i++) { char m[16], x[16]; size_t xn = 16; int n = snprintf(m, sizeof m, "p%d", i); nng_send(psock, m, n, 0); char *b; if (!nng_recv(psock, &b, &xn, NNG_FLAG_ALLOC)) { if (xn == (size_t)n && !memcmp(m, b, n)) pp++; nng_free(b, xn); } }
  pthread_t th; pthread_create(&th, NULL, burst_sender, NULL); int got = 0, inorder = 1; for (int i = 0; i < 2000; i++) { char e[16]; int en = snprintf(e, sizeof e, "b%d", i); char *b; size_t bn; if (nng_recv(psock, &b, &bn, NNG_FLAG_ALLOC)) break; got++; if (bn != (size_t)en || memcmp(e, b, en)) inorder = 0; nng_free(b, bn); }
  pthread_join(th, NULL); printf("pair bidirectional: ping-pong %d/100, burst %d/2000 in order=%d\n", pp, got, inorder);
  /* churn */
  long last = 0, slast = 0; nng_tls_config *shared = mkcfg(0, "client", "ca.pem", "localhost");
  for (int i = 1; i <= churn; i++) { nng_socket c; nng_req0_open(&c); nng_socket_set_ms(c, NNG_OPT_RECVTIMEO, 3000); nng_socket_set_ms(c, NNG_OPT_SENDTIMEO, 3000);
    if (!dial_tls(c, p, shared)) { size_t n = 8; char t[8]; req_once(c, "x", 1, t, &n); } 
    if (i % 1000 == 0) { long sr = server_rss(c); long x = rss(); printf("%5d connect/close: client RSS %.2f MiB, server RSS %.2f MiB", i, x / MiB, sr / MiB); if (last) printf("  (client %+ld B/conn, server %+ld B/conn)", (x - last) / 1000, (sr - slast) / 1000); printf("\n"); last = x; slast = sr; }
    nng_close(c); }
  return 0; }
int main(int argc, char **argv) { dir = argv[3]; if (!strcmp(argv[1], "server")) return server(atoi(argv[2])); return client(atoi(argv[2]), atoi(argv[4])); }
