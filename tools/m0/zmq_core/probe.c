/* ZeroMQ CURVE footprint probe (throwaway measurement). Usage:
   probe keygen NAME DIR | probe server PORT DIR | probe client PORT DIR CHURN
   DIR holds server.{pub,sec}, client.{pub,sec}, rogue.{pub,sec}. Ports: PORT rep, +1 pull, +2 router. */
#include <zmq.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
static double MiB = 1048576.0;
static long rss(void) { long a, b = 0; FILE *f = fopen("/proc/self/statm", "r"); if (fscanf(f, "%ld %ld", &a, &b) != 2) b = 0; fclose(f); return b * 4096; }
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
static const char *dir; static void *ctx;
static void readkey(const char *n, const char *ext, char *out) { char p[300]; snprintf(p, sizeof p, "%s/%s.%s", dir, n, ext); FILE *f = fopen(p, "r"); if (!f || fscanf(f, "%40s", out) != 1) { fprintf(stderr, "no key %s\n", p); exit(2); } fclose(f); }
/* ---- ZAP handler: only client public keys from the allow-list are accepted ---- */
static char allowed[41];
static void *zap(void *a) { void *h = zmq_socket(ctx, ZMQ_REP); zmq_bind(h, "inproc://zeromq.zap.01");
  for (;;) { char f[7][64]; int len[7] = {0}; int i = 0; int more; size_t ms = sizeof more;
    do { len[i] = zmq_recv(h, f[i], 63, 0); if (len[i] < 0) return NULL; if (len[i] > 63) len[i] = 63; zmq_getsockopt(h, ZMQ_RCVMORE, &more, &ms); i++; } while (more && i < 7);
    int ok = 0; if (i >= 7 && len[5] == 5 && !memcmp(f[5], "CURVE", 5) && len[6] == 32) { char z85[41]; zmq_z85_encode(z85, (uint8_t *)f[6], 32); ok = !strcmp(z85, allowed); }
    zmq_send(h, "1.0", 3, ZMQ_SNDMORE); zmq_send(h, f[1], len[1], ZMQ_SNDMORE); zmq_send(h, ok ? "200" : "400", 3, ZMQ_SNDMORE);
    zmq_send(h, ok ? "OK" : "denied", ok ? 2 : 6, ZMQ_SNDMORE); zmq_send(h, "", 0, ZMQ_SNDMORE); zmq_send(h, "", 0, 0); } }
/* ---- server ---- */
static void *rep, *pull, *rtr; static long pulled;
static void *t_rep(void *a) { char b[64]; for (;;) { int n = zmq_recv(rep, b, 63, 0); if (n < 0) continue; char out[64]; int m;
    if (n == 1 && b[0] == 'R') m = snprintf(out, sizeof out, "%ld", rss()); else if (n == 1 && b[0] == 'S') m = snprintf(out, sizeof out, "%ld", pulled); else { memcpy(out, b, n); m = n; }
    zmq_send(rep, out, m, 0); } }
static void *t_pull(void *a) { static char b[70000]; for (;;) { int n = zmq_recv(pull, b, sizeof b, 0); if (n > 0) pulled += n; } }
static void *t_rtr(void *a) { for (;;) { char id[64], b[64]; int il = zmq_recv(rtr, id, 64, 0); if (il < 0) continue; int n = zmq_recv(rtr, b, 64, 0); if (n < 0) continue; zmq_send(rtr, id, il, ZMQ_SNDMORE); zmq_send(rtr, b, n, 0); } }
static void secure_server(void *s, const char *sec) { int one = 1; zmq_setsockopt(s, ZMQ_CURVE_SERVER, &one, sizeof one); zmq_setsockopt(s, ZMQ_CURVE_SECRETKEY, sec, 40); zmq_setsockopt(s, ZMQ_ZAP_DOMAIN, "global", 6); }
static int server(int port) {
  char sec[41], pub[41]; readkey("server", "sec", sec); readkey("server", "pub", pub); readkey("client", "pub", allowed); ctx = zmq_ctx_new();
  pthread_t t; pthread_create(&t, NULL, zap, NULL); zmq_sleep(0);
  rep = zmq_socket(ctx, ZMQ_REP); pull = zmq_socket(ctx, ZMQ_PULL); rtr = zmq_socket(ctx, ZMQ_ROUTER); int hwm = 8, one = 1, rh = 100;
  zmq_setsockopt(pull, ZMQ_RCVHWM, &hwm, sizeof hwm); zmq_setsockopt(rtr, ZMQ_SNDHWM, &rh, sizeof rh); zmq_setsockopt(rtr, ZMQ_ROUTER_MANDATORY, &one, sizeof one);
  secure_server(rep, sec); secure_server(pull, sec); secure_server(rtr, sec); char a[64];
  snprintf(a, sizeof a, "tcp://127.0.0.1:%d", port); zmq_bind(rep, a); snprintf(a, sizeof a, "tcp://127.0.0.1:%d", port + 1); zmq_bind(pull, a); snprintf(a, sizeof a, "tcp://127.0.0.1:%d", port + 2); zmq_bind(rtr, a);
  printf("server up, curve=%d, RSS %.1f MiB\n", zmq_has("curve"), rss() / MiB); fflush(stdout);
  pthread_create(&t, NULL, t_rep, NULL); pthread_create(&t, NULL, t_pull, NULL); pthread_create(&t, NULL, t_rtr, NULL); for (;;) zmq_sleep(1); }
/* ---- client ---- */
static char spub[41], cpub[41], csec[41];
static void *mk(int type, int port, const char *serverkey, const char *pub, const char *sec) { void *s = zmq_socket(ctx, type); int t = 2500, l = 0, hwm = 8;
  zmq_setsockopt(s, ZMQ_RCVTIMEO, &t, sizeof t); zmq_setsockopt(s, ZMQ_SNDTIMEO, &t, sizeof t); zmq_setsockopt(s, ZMQ_LINGER, &l, sizeof l); zmq_setsockopt(s, ZMQ_SNDHWM, &hwm, sizeof hwm); zmq_setsockopt(s, ZMQ_RCVHWM, &hwm, sizeof hwm);
  if (serverkey) { zmq_setsockopt(s, ZMQ_CURVE_SERVERKEY, serverkey, 40); zmq_setsockopt(s, ZMQ_CURVE_PUBLICKEY, pub, 40); zmq_setsockopt(s, ZMQ_CURVE_SECRETKEY, sec, 40); }
  char a[64]; snprintf(a, sizeof a, "tcp://127.0.0.1:%d", port); zmq_connect(s, a); return s; }
static int req_once(void *s, const char *m, int n, char *out, int *on) { if (zmq_send(s, m, n, 0) < 0) return -1; char b[64]; int r = zmq_recv(s, b, 63, 0); if (r < 0) return -1; if (out) { memcpy(out, b, r); *on = r; } return 0; }
static void *dl; static void *burst(void *a) { char m[16]; for (int i = 0; i < 2000; i++) { int n = snprintf(m, sizeof m, "b%d", i); zmq_send(dl, m, n, 0); } return NULL; }
static int client(int p, int churn) {
  char rpub[41], rsec[41]; readkey("server", "pub", spub); readkey("client", "pub", cpub); readkey("client", "sec", csec); readkey("rogue", "pub", rpub); readkey("rogue", "sec", rsec); ctx = zmq_ctx_new();
  printf("process start:                       %.1f MiB\n", rss() / MiB);
  void *s = mk(ZMQ_REQ, p, spub, cpub, csec); char o[64]; int on = 0, q = req_once(s, "hi", 2, o, &on);
  printf("after CURVE connect + 1 request (%s): %.1f MiB\n", q ? "FAILED" : "ok", rss() / MiB);
  struct { const char *label; const char *sk, *pub, *sec; } bad[] = {{"plain client (no CURVE)", NULL, NULL, NULL}, {"unknown client key (rogue)", spub, rpub, rsec}, {"wrong server key", rpub, cpub, csec}};
  for (int i = 0; i < 3; i++) { void *b = mk(ZMQ_REQ, p, bad[i].sk, bad[i].pub, bad[i].sec); int t = 1500; zmq_setsockopt(b, ZMQ_RCVTIMEO, &t, sizeof t); int r = req_once(b, "x", 1, NULL, NULL); printf("%-28s %s\n", bad[i].label, r ? "rejected" : "ACCEPTED (bad)"); zmq_close(b); }
  int ok = 0; double t0 = now(); for (int i = 0; i < 2000; i++) { char m[32], x[64]; int xn = 0, n = snprintf(m, sizeof m, "m%d", i); if (!req_once(s, m, n, x, &xn) && xn == n && !memcmp(m, x, n)) ok++; }
  printf("request/reply: %d/2000 correct, %.0f req/s\n", ok, 2000 / (now() - t0));
  void *ps = mk(ZMQ_PUSH, p + 1, spub, cpub, csec); static char chunk[65536]; memset(chunk, 'x', sizeof chunk); long r0 = rss(), rmax = r0; int sent = 0; t0 = now();
  for (int i = 0; i < 4096; i++) { if (zmq_send(ps, chunk, sizeof chunk, 0) > 0) sent++; if (i % 256 == 0 && rss() > rmax) rmax = rss(); } double dt = now() - t0; zmq_sleep(1);
  char so[64] = {0}; int sn = 0; req_once(s, "S", 1, so, &sn); printf("push 256 MiB: sent %d/4096, server received %.0f MiB, %.0f MiB/s, client RSS growth %.1f MiB\n", sent, atol(so) / MiB, sent * 64.0 / 1024 / dt, (rmax - r0) / MiB);
  dl = mk(ZMQ_DEALER, p + 2, spub, cpub, csec); int pp = 0; for (int i = 0; i < 100; i++) { char m[16], x[16]; int n = snprintf(m, sizeof m, "p%d", i); zmq_send(dl, m, n, 0); int r = zmq_recv(dl, x, 16, 0); if (r == n && !memcmp(m, x, n)) pp++; }
  /* ZeroMQ sockets are not thread-safe: send and receive from one thread with poll */
  int got = 0, sent2 = 0, inorder = 1;
  while (got < 2000) { zmq_pollitem_t it = {dl, 0, (short)(ZMQ_POLLIN | (sent2 < 2000 ? ZMQ_POLLOUT : 0)), 0}; if (zmq_poll(&it, 1, 3000) <= 0) break;
    if (it.revents & ZMQ_POLLIN) { char e[16], x[16]; int en = snprintf(e, sizeof e, "b%d", got); int r = zmq_recv(dl, x, 16, 0); if (r < 0) break; if (r != en || memcmp(e, x, en)) inorder = 0; got++; }
    if ((it.revents & ZMQ_POLLOUT) && sent2 < 2000) { char m[16]; int n = snprintf(m, sizeof m, "b%d", sent2); if (zmq_send(dl, m, n, ZMQ_DONTWAIT) > 0) sent2++; } }
  printf("dealer/router bidirectional: ping-pong %d/100, burst %d/2000 in order=%d\n", pp, got, inorder);
  long last = 0, slast = 0;
  for (int i = 1; i <= churn; i++) { void *c = mk(ZMQ_REQ, p, spub, cpub, csec); char t[64]; int n = 0; req_once(c, "x", 1, t, &n);
    if (i % 1000 == 0) { char ro[64] = {0}; int rn = 0; req_once(c, "R", 1, ro, &rn); long sr = atol(ro), x = rss(); printf("%5d connect/close: client RSS %.2f MiB, server RSS %.2f MiB", i, x / MiB, sr / MiB); if (last) printf("  (client %+ld B/conn, server %+ld B/conn)", (x - last) / 1000, (sr - slast) / 1000); printf("\n"); last = x; slast = sr; }
    zmq_close(c); }
  return 0; }
int main(int argc, char **argv) { if (!strcmp(argv[1], "keygen")) { char pub[41], sec[41]; if (zmq_curve_keypair(pub, sec)) return 1; dir = argv[3]; char p[300]; snprintf(p, sizeof p, "%s/%s.pub", dir, argv[2]); FILE *f = fopen(p, "w"); fprintf(f, "%s\n", pub); fclose(f);
    snprintf(p, sizeof p, "%s/%s.sec", dir, argv[2]); f = fopen(p, "w"); fprintf(f, "%s\n", sec); fclose(f); return 0; }
  dir = argv[3]; if (!strcmp(argv[1], "server")) return server(atoi(argv[2])); return client(atoi(argv[2]), atoi(argv[4])); }
