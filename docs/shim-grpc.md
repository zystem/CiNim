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

**One channel, a request after a request** (what a shim does; `-d:release --opt:size`, as the images are built; nim-grpc with the copy fixes, session resumption, fewer copies and a 1 MiB HTTP/2
window, PR #11; the container pinned to cores 0-3, three runs, medians; without pinning the same binaries varied 30-40% from run to run):

| | ZeroMQ + CURVE | gRPC + mTLS |
|:--|--:|--:|
| new channel and its first request, median | 1.0-1.3 ms | 0.6-0.8 ms (a connection after the first one of the process, see below) |
| 256 B, median | 0.038-0.041 ms | 0.041-0.045 ms |
| 64 KiB, median; throughput | 0.45-0.48 ms; 134-143 MB/s | 0.26 ms; 235-251 MB/s |
| 900 KB, median; throughput | 5.9-6.1 ms; 146-152 MB/s | 2.7 ms; 323-332 MB/s |
| CPU of the client for the series | 1.01-1.05 s | 0.85-0.89 s |
| CPU of the server for the same | 1.00-1.04 s | 0.80-0.84 s |
| peak RSS, client / server | 6 / 5 MB | 14-15 / 13-15 MB |
| threads, client / server | 1 / 3 | 3 / 7 |

gRPC is now faster than ZeroMQ on 64 KiB and larger, uses about 17% less CPU for the series, and is within 10% on 256 B; it takes more memory (the 1 MiB window lets a peer leave up to 1 MiB unread
per connection) and more threads. **The first request** is fast because the 40 repeats of the benchmark share one `TlsConfig` (`common/corechannel.nim` keeps one per directory of keys), so every
channel after the first resumes the TLS session of the previous one (ten minutes in nim-grpc, `setSessionLifetime`) and skips the public-key work; the first connection of a process, and one after
the shim restarted, still takes about 3 ms. A resumed session is not checked against the certificate again, so a revoked shim certificate keeps working for up to ten minutes. For comparison,
before the fixes gRPC took 18 ms for the first request, 5.7 ms for 64 KiB, 65 ms for 900 KB and 12 s of CPU on the client (`--opt:size`, unpinned).

**Where the time went** (`perf record` on a gRPC echo of 900 KB messages with TLS, before the fixes; the first reading, that BearSSL's crypto is the cost, was wrong): 36.5% + 30.7% + 4.7% of the
samples were `system.add`, `system.setLen` and slicing of `seq[byte]` (Nim's element-by-element copy and byte-wise zero fill), against 2% + 1.8% for AES-GCM with AES-NI and PCLMUL. nim-grpc now copies
with `copyMem` into uninitialised buffers, builds a received message straight from the DATA chunks and keeps the 5-byte frame prefix apart on send. In nim-grpc's own loopback benchmark, pinned,
the TLS throughput is about 370 MB/s and plain about 600 MB/s.

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
2. **TLS 1.2 only** (BearSSL has no 1.3; the cipher in use is hardware AES-GCM, see above). CURVE has no version and no certificates. Certificates expire: a set made for two years is an operational item (rotation, a clock that is
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

* The shim gets smaller and simpler to build (no C++, no libsodium, no libzmq); that is real and it is the strongest argument. Its bytes cost about 7 times more CPU in nim-grpc as it is;
  the profile says that is the copying of `seq[byte]` and not the crypto, so most of it can be got back by a change in the library. It does not matter for the sizes a step sends (compressed
  log blocks, a report of a few hundred bytes) and matters for the fallback path that carries artifact bytes through the core (the direct path of D-61 does not use this channel for bytes).
* The core pays for connections: with the blocking server it is the number of threads, with CPU about 7 times per byte on top (the same copying; the server pays it too). For a shard with many steps at once the blocking server is not a
  choice; the chronos one has to be tried, and that is a bigger piece of work than this branch.
* Mutual TLS gives what CURVE did not: certificates with names and expiry, revocation by replacing the CA, standard tooling. It costs a certificate lifecycle.

Nothing in the branch is committed or pushed.
