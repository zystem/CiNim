/* Native nats.c client footprint probe (throwaway measurement, same idea as grpc_core/rss_client.c).
   Usage: probe PORT CERTDIR CHURN */
#include <nats/nats.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static double MiB = 1048576.0;
static long rss(void) { long a, b = 0; FILE *f = fopen("/proc/self/statm", "r"); if (fscanf(f, "%ld %ld", &a, &b) != 2) b = 0; fclose(f); return b * 4096; }
static char url[64], ca[256], crt[256], key[256];
static natsStatus conn(natsConnection **nc, const char *cafile, const char *cert, const char *k) {
  natsOptions *o = NULL; natsOptions_Create(&o); natsOptions_SetURL(o, url); natsOptions_SetSecure(o, true);
  natsOptions_SetExpectedHostname(o, "localhost"); natsOptions_SetMaxReconnect(o, 0); natsOptions_SetTimeout(o, 3000);
  if (cafile) natsOptions_LoadCATrustedCertificates(o, cafile);
  if (cert) natsOptions_LoadCertificatesChain(o, cert, k);
  natsStatus s = natsConnection_Connect(nc, o); natsOptions_Destroy(o); return s; }
static void echo(natsConnection *nc, natsSubscription *sub, natsMsg *m, void *cl) {
  natsConnection_Publish(nc, natsMsg_GetReply(m), natsMsg_GetData(m), natsMsg_GetDataLength(m)); natsMsg_Destroy(m); }
int main(int argc, char **argv) {
  snprintf(url, sizeof url, "tls://%s:%s", argc > 4 ? argv[4] : "localhost", argv[1]);
  snprintf(ca, sizeof ca, "%s/ca.pem", argv[2]); snprintf(crt, sizeof crt, "%s/client.pem", argv[2]); snprintf(key, sizeof key, "%s/client.key", argv[2]);
  char rc[256], rk[256], rca[256]; snprintf(rc, sizeof rc, "%s/rogue.pem", argv[2]); snprintf(rk, sizeof rk, "%s/rogue.key", argv[2]); snprintf(rca, sizeof rca, "%s/rogue-ca.pem", argv[2]);
  int churn = atoi(argv[3]); natsConnection *nc = NULL, *nc2 = NULL; natsStatus s;
  printf("process start:                       %.1f MiB\n", rss() / MiB);
  nats_Open(-1); printf("after nats_Open:                     %.1f MiB\n", rss() / MiB);
  s = conn(&nc, ca, crt, key); if (s != NATS_OK) nats_PrintLastErrorStack(stderr); printf("after mTLS connect (%s):        %.1f MiB\n", natsStatus_GetText(s), rss() / MiB);
  natsConnection *bad = NULL;
  printf("no client cert:        %s\n", (s = conn(&bad, ca, NULL, NULL)) == NATS_OK ? "ACCEPTED (bad)" : natsStatus_GetText(s)); if (bad) natsConnection_Destroy(bad); bad = NULL;
  printf("foreign-CA client cert: %s\n", (s = conn(&bad, ca, rc, rk)) == NATS_OK ? "ACCEPTED (bad)" : natsStatus_GetText(s)); if (bad) natsConnection_Destroy(bad); bad = NULL;
  printf("untrusted server:      %s\n", (s = conn(&bad, rca, crt, key)) == NATS_OK ? "ACCEPTED (bad)" : natsStatus_GetText(s)); if (bad) natsConnection_Destroy(bad);
  /* request/reply ping-pong (echo responder on a second connection) */
  natsSubscription *sub = NULL; s = conn(&nc2, ca, crt, key); printf("responder connect: %s\n", natsStatus_GetText(s));
  s = natsConnection_Subscribe(&sub, nc2, "m0.echo", echo, NULL); printf("subscribe: %s\n", natsStatus_GetText(s)); natsConnection_Flush(nc2);
  int ok = 0; int64_t t0 = nats_Now(); natsMsg *r = NULL;
  for (int i = 0; i < 2000; i++) { char b[32]; int n = snprintf(b, sizeof b, "m%d", i);
    if (natsConnection_Request(&r, nc, "m0.echo", b, n, 2000) == NATS_OK) { if (natsMsg_GetDataLength(r) == n && !memcmp(natsMsg_GetData(r), b, n)) ok++; natsMsg_Destroy(r); } else { printf("request %d failed: %s\n", i, natsStatus_GetText(natsConnection_Request(&r, nc, "m0.echo", b, n, 500))); break; } }
  printf("request/reply: %d/2000 correct, %.0f req/s\n", ok, 2000 * 1000.0 / (nats_Now() - t0));
  /* 256 MiB of 64 KiB messages, core NATS, RSS while streaming */
  static char chunk[65536]; memset(chunk, 'x', sizeof chunk); long r0 = rss(), rmax = r0; t0 = nats_Now();
  for (int i = 0; i < 4096; i++) { natsConnection_Publish(nc, "m0.sink", chunk, sizeof chunk); if (i % 256 == 0) { natsConnection_FlushTimeout(nc, 10000); if (rss() > rmax) rmax = rss(); } }
  natsConnection_FlushTimeout(nc, 10000);
  printf("publish 256 MiB: %.0f MiB/s, client RSS growth %.1f MiB\n", 256.0 * 1000 / (nats_Now() - t0), (rmax - r0) / MiB);
  /* JetStream publish with server ack (what the log path needs) */
  jsCtx *js = NULL; jsErrCode jerr = 0; jsStreamConfig cfg; jsStreamConfig_Init(&cfg); const char *subs[] = {"m0.log"}; cfg.Name = "M0PROBE"; cfg.Subjects = subs; cfg.SubjectsLen = 1;
  cfg.Storage = js_FileStorage; cfg.Retention = js_LimitsPolicy; cfg.MaxBytes = 256 * 1024 * 1024; cfg.Discard = js_DiscardOld;
  natsConnection_JetStream(&js, nc, NULL); s = js_AddStream(NULL, js, &cfg, NULL, &jerr);
  if (s != NATS_OK) printf("js_AddStream: %s (err %d)\n", natsStatus_GetText(s), (int)jerr);
  static char lg[16384]; memset(lg, 'l', sizeof lg); jsPubAck *ack = NULL; int acked = 0; t0 = nats_Now();
  for (int i = 0; i < 2000; i++) { if (js_Publish(&ack, js, "m0.log", lg, sizeof lg, NULL, &jerr) == NATS_OK) { acked++; jsPubAck_Destroy(ack); } }
  printf("jetstream sync publish (16 KiB): %d/2000 acked, %.0f msg/s, RSS %.1f MiB\n", acked, 2000 * 1000.0 / (nats_Now() - t0), rss() / MiB);
  js_DeleteStream(js, "M0PROBE", NULL, &jerr); jsCtx_Destroy(js);
  natsSubscription_Destroy(sub); natsConnection_Destroy(nc2);
  /* connection churn: client RSS every 1000 connections */
  long last = 0;
  for (int i = 1; i <= churn; i++) { natsConnection *c = NULL; if (conn(&c, ca, crt, key) == NATS_OK) natsConnection_Destroy(c);
    if (i % 1000 == 0) { long x = rss(); printf("%5d connect/close cycles: client RSS %.2f MiB", i, x / MiB); if (last) printf("  (%+ld B/conn)", (x - last) / 1000); printf("\n"); last = x; } }
  natsConnection_Destroy(nc); nats_CloseAndWait(0); return 0; }
