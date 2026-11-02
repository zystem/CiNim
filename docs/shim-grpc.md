# The shim's channels over gRPC (experiment, branch `shim-grpc`)

The owner (2026-11-02) asked for the shim to be rewritten on [nim-grpc](https://github.com/zystem/nim-grpc) in a branch and compared with the ZeroMQ + CURVE it has today (D-24). This is what was
built, how it compares, and what it would take to merge. Nothing here is a decision: the comparison is the input to one (a D-xx entry would follow).

## What was changed

The four channels of a step Pod to the core are unchanged in shape: one request, one answer, protobuf messages of `proto/`, the ports 19742 (report), 19743 (log), 19744 (artifacts), 19746 (state).
Only the transport is replaced.

| Part | Before | Now |
|:--|:--|:--|
| Shim client | `connectReq` / `send` / `waitForReceive` (`common/zmqcurve.nim`) at six places of `shim/logclient.nim` | `dialCore` / `exchange` (`common/corechannel.nim`, 89 lines): the same call sites, one line each |
| Core servers | a REP socket and a thread per channel (`serveLogIngest`, `serveStepReport`, `serveStatus`, `serveArtifactIngest`) | a gRPC server per channel and port (`core/grpcserve.nim`, 26 lines); the handlers `answerLogBatch`, `answerStepReport`, `answerStatus` and the new `answerArtifact` are the same code, called under a lock |
| Identity | CURVE keypairs `curve/core.*`, `curve/client.*`, one client identity for all shims | mutual TLS: `tls/ca.pem`, `tls/core.{pem,key}`, `tls/client.{pem,key}`; one client identity for all shims, as before (SEC-010 is still deferred); made by `tools/grpc/gen_tls.sh` |
| Methods | the socket | `/cicd.LogIngest/Send`, `/cicd.StepReport/Report`, `/cicd.Status/Report`, `/cicd.ArtifactIngest/Call` (nim-grpc's untyped API: the bytes of the existing messages; no `service` was added to `proto/`) |
| Not touched | | the controller and conductor channels (19745 and the executor), which still use ZeroMQ; the core links both |

The shim checks the core's certificate against the fixed name `cinim-core`, not against the address it dials, so one certificate serves every namespace. A step Pod needs `ca.pem`, `client.pem`
and `client.key`, never `core.key`.

Build: nim-grpc needs a static nghttp2 (`-d:nghttp2Prefix`), zlib and the Nim package `bearssl`; `config.nims` reads `NIM_GRPC` (the checkout), `NIM_BEARSSL` and `NGHTTP2_PREFIX`. The shim no longer
needs libzmq, libsodium or a C++ toolchain.

## Tests

* `tests/unit/tcorechannel.nim` (8): an answer comes back byte for byte (empty to 1 MB), a slow core is "no answer" and the next request goes on, a core that is not there is "no answer", a
  certificate of another CA is refused (and the right one is served), unreadable keys are an error, an unknown method is an error, a restarted core is reached again within two requests.
* `tests/unit/tshimgrpc.nim` (2 tests, and the setup and teardown that count as two more): the shim's log pipeline (2000 lines through the spool and the sender thread, with the state channel) reaches the real `serveLogIngest` and a stand-in for vlagent and is
  acknowledged; the report and the request for secrets are answered by the real handlers.
* `tests/integration/tshimdirect.nim`: the whole artifact chain (shim, core, storage module, Caddy nodes; upload by parts, read back, caches, the refusals) passes over the new channel.
* `tshim`, `tdrainpod`, `tlogcollector`, `tboundaries`, `tpipelineflow` pass; `tshim` has one failure that is the same on `main` in the same image (busybox `ps` has no `-o ni=,pgid=`).
* Not run: the rest of the suite, a real cluster, a real core with a real shim in a Pod.

## The comparison

All numbers are from one machine, loopback, the images of `tools/image/Dockerfile.deps` (Alpine, musl, Nim 2.2.12). `tools/bench/shimtransport.nim` runs the two transports with the code the shim
uses and an echo server, so what is measured is the transport and nothing the core does.

**Size** (static, stripped; the shim is also UPX-packed because it travels in a ConfigMap):

| | `main` | `shim-grpc` |
|:--|--:|--:|
| shim | 1 883 608 B | 1 053 808 B (-44%) |
| shim, UPX | 639 144 B | 396 572 B (-38%) |
| core | 9 983 224 B | 10 409 720 B (+4.3%) |

**One channel, a request after a request** (what a shim does; `-d:release --opt:size`, as the images are built):

| | ZeroMQ + CURVE | gRPC + mTLS |
|:--|--:|--:|
| new channel and its first request, median (p95) | 3.6 ms (4.5) | 18 ms (21) |
| 256 B, median (p99) | 0.073 ms (0.19) | 0.19 ms (0.52) |
| 64 KiB, median; throughput | 0.88 ms; 64 MB/s | 5.7 ms; 12 MB/s |
| 900 KB, median; throughput | 6.9 ms; 107 MB/s | 65 ms; 14 MB/s |
| CPU of the client for the series (about 250 MB each way) | 1.7 s | 12.2 s |
| CPU of the server for the same | 3.1 s | 22 s |

With `--opt:speed` gRPC is up to twice as fast (64 KiB: 24 MB/s; 900 KB: 18 MB/s; first request 8 ms) and the order of the two does not change. The cost is BearSSL (TLS 1.2, software
crypto) and the HTTP/2 framing, against libsodium's CURVE; where the time goes inside was not profiled.

**Many shims at once** (32 clients, 100 requests of 64 KiB each, `--opt:speed`): the whole batch took about 1.0 s on ZeroMQ (one REP thread) and about 0.8 s on gRPC (the TLS work of the
connections spreads over the cores; the handler itself is still one at a time). A server is not the limit for the log of a few shims; the CPU is.

**Connected shims, idle** (the core's side; each held one connection after one request):

| connections | ZeroMQ: threads, RSS | gRPC (blocking server): threads, RSS |
|--:|--:|--:|
| 0 | 3, 4 MB | 2, 3.6 MB |
| 100 | 3, 7.8 MB | 205, 28 MB |
| 400 | 3, 18.5 MB | 631, 84 MB |

nim-grpc's blocking server gives every connection a reader and a writer thread. A step has up to three connections (log, state, a report or an artifact call), so 500 steps at once would be about
1500 connections and 2500 threads, and 300 MB. nim-grpc also has a chronos server that serves many connections on one thread (its documentation says so; **not tried here**); the core would then
call its blocking database client from a worker, which is another piece of work.

## What was found on the way

1. **nim-grpc's `dial` blocks in `connect(2)` with no deadline** (and name resolution too): a core behind a rule that drops packets would hold a shim for minutes, where a ZeroMQ connect returns at
   once. `corechannel.nim` makes a probe connect with a 5 s deadline first (one extra TCP connection per channel). The right fix is a connect timeout in nim-grpc.
2. **TLS 1.2 only**, with BearSSL's software crypto. CURVE has no version and no certificates. Certificates expire: a set made for two years is an operational item (rotation, a clock that is
   right in the Pod) that CURVE keys never were.
3. **The REP socket serialised requests for free;** now a lock does (`grpcserve.nim`), so the state a handler touches (the database client of the thread, the collector) is used by one request at a
   time, as before. Real concurrency is possible but needs a database client per worker and a look at the shared state in `logcollector.nim`.
4. **The liveness beat** (`beat(bLogIngest)` and the others, read by the health check) used to stop when a REP loop was stuck in a handler. The serving loop now beats on its own; a handler stuck
   under the lock is not seen. A beat from the handler would restore it.
5. **A rollout has two versions.** The controller puts the shim of its own version in the Pods; a core that only speaks gRPC cannot serve Pods made before it. A merge needs both transports on
   different ports for one release, or a drain of the runs.
6. **The Secrets and the chart change:** the shim's certificates directory today holds `curve/`; it would hold `tls/` (the controller mounts it, `deploy/charts/cinim-shard`), and the core's
   needs `tls/core.*` and `tls/ca.pem`. Not done on the branch.
7. **The images:** `tools/image/Dockerfile.deps` has no nghttp2 and no `bearssl`; the branch was built against a static nghttp2 1.68.0 made by the recipe of nim-grpc's `docs/static-build.md` and
   against the host's Nim package. `cinim.nimble` does not list nim-grpc yet.
8. **The host environment:** `import protobuf_serialization` does not compile with the Nim packages in the host's `~/.nimble/pkgs2` now (`serialization` 0.5.4 with `stew` 0.5.2 and 0.6.5:
   `readPragma` is undeclared), also on `main`; every build and test here ran in the deps image.

## Reading of the numbers

* The shim gets smaller and simpler to build (no C++, no libsodium, no libzmq); that is real and it is the strongest argument. Its bytes go through a TLS stack that costs about 7 times more
  expensive per byte, which does not matter for the sizes a step sends (compressed log blocks, a report of a few hundred bytes) and matters for the fallback path that carries artifact bytes
  through the core (the direct path of D-61 does not use this channel for bytes).
* The core pays for connections: with the blocking server it is the number of threads, with CPU about 7 times per byte on top. For a shard with many steps at once the blocking server is not a
  choice; the chronos one has to be tried, and that is a bigger piece of work than this branch.
* Mutual TLS gives what CURVE did not: certificates with names and expiry, revocation by replacing the CA, standard tooling. It costs a certificate lifecycle.

Nothing in the branch is committed or pushed.
