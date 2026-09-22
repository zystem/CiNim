/* JetStream publisher throughput through nats.c (what core's log collector would use): async publish with a pending window.
   Usage: pub_probe NATS_URL MSGS BYTES */
#include <nats/nats.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(int argc, char **argv) {
  int n = atoi(argv[2]); size_t sz = (size_t)atol(argv[3]); natsConnection *nc = NULL; jsCtx *js = NULL; jsErrCode ec = 0; jsOptions o; natsStatus s;
  s = natsConnection_ConnectTo(&nc, argv[1]); if (s) { printf("connect: %s\n", natsStatus_GetText(s)); return 1; }
  jsOptions_Init(&o); o.PublishAsync.MaxPending = 256; natsConnection_JetStream(&js, nc, &o);
  jsStreamConfig cfg; jsStreamConfig_Init(&cfg); const char *subs[] = {"pubprobe.>"}; cfg.Name = "PUBPROBE"; cfg.Subjects = subs; cfg.SubjectsLen = 1;
  cfg.Storage = js_FileStorage; cfg.MaxBytes = 512 * 1024 * 1024; cfg.Discard = js_DiscardOld;
  s = js_AddStream(NULL, js, &cfg, NULL, &ec); if (s) { printf("add stream: %s %d\n", natsStatus_GetText(s), (int)ec); }
  char *buf = malloc(sz); memset(buf, 'x', sz); int64_t t0 = nats_Now(); int sent = 0;
  for (int i = 0; i < n; i++) { for (;;) { s = js_PublishAsync(js, "pubprobe.logs", buf, (int)sz, NULL);
      if (s == NATS_OK) { sent++; break; } if (s == NATS_TIMEOUT) continue; /* window full: the call waited (StallWait) */ printf("publish: %s\n", natsStatus_GetText(s)); return 2; } }
  jsPubOptions po; jsPubOptions_Init(&po); po.MaxWait = 60000; s = js_PublishAsyncComplete(js, &po);
  double dt = (nats_Now() - t0) / 1000.0;
  printf("%d messages of %zu KiB acked by JetStream: %s in %.2f s = %.0f msg/s = %.1f MiB/s\n", sent, sz / 1024, natsStatus_GetText(s), dt, sent / dt, sent * (double)sz / 1048576 / dt);
  js_DeleteStream(js, "PUBPROBE", NULL, &ec); return 0; }
