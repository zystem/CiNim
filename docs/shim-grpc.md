# The channels over gRPC with mutual TLS (D-104)

The owner (2026-11-02) asked for the shim to be rewritten on [nimgrpc](https://github.com/zystem/nimgrpc) in a branch and compared with the ZeroMQ + CURVE it had (D-24). The comparison below came out
in gRPC's favour once the library had its copy fixes, and the owner (2026-11-03: "коммитить отдельно shim нет смысла. надо переключать на grpc все компоненты") had **every component** switched: the shim, the
core's servers, the controllers and the conductors. ZeroMQ, libzmq and the fork `nim-zmq` are gone from the repository. This page keeps the comparison and the findings; the decision is D-104.

## What was changed

The four channels of a step Pod to the core are unchanged in shape: one request, one answer, protobuf messages of `proto/`, the ports 19742 (report), 19743 (log), 19744 (artifacts), 19746 (state).
The push channel of the controllers and the conductors (19745, docs/conductors.md section 12) is the same frames over two long calls of a client. Only the transport is replaced.

| Part | Before | Now |
|:--|:--|:--|
| Shim client | `connectReq` / `send` / `waitForReceive` (`common/zmqcurve.nim`) at six places of `shim/logclient.nim` | `dialCore` / `exchange` (`common/corechannel.nim`): the same call sites, one line each |
| Core servers for the shim | a REP socket and a thread per channel (`serveLogIngest`, `serveStepReport`, `serveStatus`, `serveArtifactIngest`) | a gRPC server per channel and port (`core/grpcserve.nim`); the handlers `answerLogBatch`, `answerStepReport`, `answerStatus` and the new `answerArtifact` are the same code, called under a lock |
| The push channel | a ROUTER in the core, a DEALER in each client (`common/stream.nim`), ZeroMQ heartbeats 3 s / 10 s, `ROUTER_MANDATORY` | a gRPC server in the core and, in each client, a thread that connects and opens two calls on one connection: `/cicd.Stream/Down` (the core pushes) and `/cicd.Stream/Up` (the client sends); HTTP/2 keepalive 3 s / 10 s; the frame envelope, the numbering, the acknowledgements and `resync` are the same bytes and the same code (`streamstate.nim`, `streamhub.nim`) |
| Identity | CURVE keypairs `curve/core.*`, `curve/client.*`, one client identity for all | mutual TLS: `tls/ca.pem`, `tls/core.{pem,key}`, `tls/client.{pem,key}`; one client identity for all, as before (SEC-010 is still deferred); made by `tools/grpc/gen_tls.sh`; the core's own secret (the identities of the controllers are made under it, and the derived master key of the secrets) is `tls/master.key`, not a TLS key |
| Methods | the socket | `/cicd.LogIngest/Send`, `/cicd.StepReport/Report`, `/cicd.Status/Report`, `/cicd.ArtifactIngest/Call`, `/cicd.Stream/Down`, `/cicd.Stream/Up` (nimgrpc's untyped API: the bytes of the existing messages; no `service` was added to `proto/`) |
| Secrets and mounts | the Secret `cinim-controller-curve` (`core.pub`, `client.pub`, `client.key`) at `/etc/cinim/curve`; in a step Pod `cicd-curve-certs` | the Secret `cinim-controller-tls` (`ca.pem`, `client.pem`, `client.key`) at `/etc/cinim/tls`; in a step Pod `cicd-tls-certs`; the chart value `tls.secretName` (five files) in place of `curve.secretName`, or, by default, certificates issued by cert-manager (D-105); the core's own secret is in its database |

A client checks the core's certificate against the fixed name `cinim-core`, not against the address it dials, so one certificate serves every namespace. A step Pod, a controller and a conductor need `ca.pem`,
`client.pem` and `client.key`, never `core.key` or `master.key`.

How a peer of the push channel is told: the client makes a token at every connect (16 random bytes) and puts it in the metadata `cinim-peer` of both calls; it is the routing id, the address of the peer's last frame, and it changes at every
reconnect, as a ZeroMQ routing id did. The `Down` call is opened first and the core answers it with an empty message once the peer is registered, so the client sends nothing before the core can answer. Two calls and not one bidirectional call because
each is then used by one thread on each side (a call of nimgrpc is not meant to be read and written by two). Frames cross threads in `ShmQueue` (`common/shmq.nim`), never as Nim strings. A peer takes two workers of the gRPC server for as long as it is
connected (`maxWorkers` is twice the number of peers plus a few).

Build: nimgrpc is a nimble package (`requires "nimgrpc >= 0.2.0"` in `cinim.nimble`; the repository is `zystem/nimgrpc`, the modules are `nimgrpc`: `import nimgrpc`; version 0.2.0 was used). It needs a
static nghttp2 1.57 or later, which it looks for in `/opt/nghttp2` (`include/` and `lib/libnghttp2.a`; `-d:nghttp2Prefix=<dir>`, or `NGHTTP2_PREFIX` for `config.nims`, names another place), zlib, and the Nim
package `bearssl` that nimble brings. `tools/image/Dockerfile.deps` (and `Dockerfile.test`, `tools/soak/Dockerfile`, `tools/shim/build_static.sh`) build nghttp2 1.68.0. The shim, the conductor and the controller no longer need libzmq, libsodium or a C++ toolchain;
libsodium stays in the core and the storage module (the sealing of the secrets), at `/opt/sodium`.

## Tests

* `tests/unit/tstream.nim` (9 for the channel and 4 for the envelope): a frame reaches the core with a routing id and the core answers on it; two clients are told apart and a push goes to one; a send to a peer that is gone fails; a client with a certificate
  of another CA, and one that does not trust the core's CA, cannot connect; frames sent before the client is connected wait and arrive in order; a client connects to a core that comes up later and again to one that was restarted; a frame of 3 MB and 500 small ones both ways.
* `tests/unit/tcorechannel.nim` (8): an answer comes back byte for byte (empty to 1 MB), a slow core is "no answer" and the next request goes on, a core that is not there is "no answer", a
  certificate of another CA is refused (and the right one is served), unreadable keys are an error, an unknown method is an error, a restarted core is reached again within two requests.
* `tests/unit/tshimgrpc.nim`: the shim's log pipeline (2000 lines through the spool and the sender thread, with the state channel) reaches the real `serveLogIngest` and a stand-in for vlagent and is acknowledged; the report and the request for secrets are answered by the real handlers.
* `tests/integration/tstream.nim`, `tconductorhub.nim`, `tconductor.nim` (a real rqlite): the controller's and the conductor's channel as before; `tshimdirect.nim`: the whole artifact chain.
* The keys of every test are made by `tools/grpc/gen_tls.sh` into a temporary directory (`tests/support/testcerts.nim`); `tests/certs/curve` is not used any more.

## The comparison

All numbers are from one machine, loopback, the images of `tools/image/Dockerfile.deps` (Alpine, musl, Nim 2.2.12). `tools/bench/shimtransport.nim` runs the two transports with the code the shim
uses and an echo server, so what is measured is the transport and nothing the core does.

**Size** (static, stripped; the shim is also UPX-packed because it travels in a ConfigMap):

| | `main` | `shim-grpc`, `--opt:size` (as built) | `shim-grpc`, `--opt:speed` |
|:--|--:|--:|--:|
| shim | 1 883 608 B | 1 062 000 B (-44%) | 1 344 624 B (-29%) |
| shim, UPX | 639 144 B | 398 456 B (-38%) | 498 760 B (-22%) |
| core | 9 983 224 B | 10 409 720 B (+4.3%) | |

The shim with nimgrpc 0.2.0 (the figures of the first two columns of `shim-grpc` before were 1 053 808 and 396 572 B). **`--opt:speed` fits** the limit of RUN-010 (1 MiB packed) with room to spare: 487 KiB, and
it is still smaller than the ZeroMQ shim of `main`. It buys nothing measurable, though: the transport benchmark below, built both ways, gave the same medians within the noise (900 KB: 4.7 ms with `size`, 5.4 ms with `speed`;
64 KiB: 0.88 and 0.94 ms; unpinned, one run each), because the copying that used to cost the time is `copyMem` now and the crypto is C. The images stay on `--opt:size`.

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

**Many shims at once** (32 clients in parallel, 100 requests of 64 KiB each, `--opt:speed`, three runs each): the whole batch took 0.70-0.77 s on ZeroMQ (one REP thread) and 0.22-0.37 s on gRPC
(the TLS work of the connections spreads over the cores; the handler itself is still one at a time). A server is not the limit for the log of a few shims; the CPU is.

**Connected shims, idle** (the core's side; each held one connection after one request, `--opt:speed`):

| connections | ZeroMQ: threads, RSS | gRPC (blocking server): threads, RSS |
|--:|--:|--:|
| 0 | 3, 6.5 MB | 2, 5.9 MB |
| 100 | 3, 9.5 MB | 205, 31 MB |
| 400 | 3, 18 MB | 805, 103 MB |

nim-grpc's blocking server gives every connection a reader and a writer thread. A step has up to three connections (log, state, a report or an artifact call), so 500 steps at once would be about
1500 connections and 3000 threads, and 390 MB (the 1 MiB window and the buffers cost about 0.25 MB a connection now, against 0.2 before). nim-grpc also has a chronos server that serves many connections on one thread (its documentation says so; **not tried here**); the core would then
call its blocking database client from a worker, which is another piece of work.

## What was found on the way

1. **nim-grpc's `dial` blocked in `connect(2)` with no deadline** (and name resolution too): a core behind a rule that drops packets would hold a shim for minutes, where a ZeroMQ connect returns at
   once. Fixed in the library (`connectTimeoutMs`, 20 s by default); `corechannel.nim` passes 5 s and no longer makes a probe connection first. Resolving the name is still not covered.
2. **TLS 1.2 only** (BearSSL has no 1.3; the cipher in use is hardware AES-GCM, see above). CURVE has no version and no certificates. Certificates expire: a set made for two years is an operational item (rotation, a clock that is
   right in the Pod) that CURVE keys never were.
3. **The REP socket serialised requests for free;** now a lock does (`grpcserve.nim`), so the state a handler touches (the database client of the thread, the collector) is used by one request at a
   time, as before. Real concurrency is possible but needs a database client per worker and a look at the shared state in `logcollector.nim`.
4. **The liveness beat** (`beat(bLogIngest)` and the others, read by the health check) used to stop when a REP loop was stuck in a handler. The serving loop now beats on its own; a handler stuck
   under the lock is not seen. A beat from the handler would restore it.
5. **A rollout is one version.** The core, the controllers, the conductors and the shims speak gRPC only, with no second transport for a release: the core replaces the controller Pod of every organisation when its image changes (D-62), the new controller
   puts the new shim into new Pods, and the conductors are replaced with it. A **step that runs through the rollout** has an old shim, which cannot reach the new core: it loses its report and its log until it ends (the spool on the run's volume keeps the log, and the
   drain Pod delivers it, DAT-003). Roll out when few steps run, or drain the runs first. The Secrets change at the same time: with cert-manager (D-105) you make nothing: the core keeps its own secret in the database, sealed by the key of the secrets; only a shard that has secrets or identities made under the old `curve/core.key` brings it in once (`tls.masterKeySecret`); without cert-manager put the five files in the Secret named by `tls.secretName`.
6. **The Secrets and the chart are changed:** `tls.certManager` / `tls.secretName` (the chart; `tls.masterKeySecret` only to bring in an old secret), `cinim-controller-tls` and `cicd-tls-certs` (the Secrets the core and the controller make); the old `cinim-controller-curve` and `cicd-curve-certs` stay in the cluster until someone deletes them.
7. **The images:** `tools/image/Dockerfile.deps` builds a static nghttp2 1.68.0 into `/opt/nghttp2` and libsodium into `/opt/sodium`, and `nimble install --depsOnly` takes nimgrpc from the package list; `Dockerfile.test`, `tools/soak/Dockerfile` and
   `tools/shim/build_static.sh` do the same for their own base. The binaries built in the deps image: core 9.45 MB (9.98 before), controller 8.5 MB, conductor 1.07 MB, shim 392 KB packed (639 KB before).
8. **The host environment:** `import protobuf_serialization` does not compile with the Nim packages in the host's `~/.nimble/pkgs2` now (`serialization` 0.5.4 with `stew` 0.5.2 and 0.6.5:
   `readPragma` is undeclared), also on `main`; every build and test here ran in the deps image.

## Reading of the numbers

* The shim gets smaller and simpler to build (no C++, no libsodium, no libzmq); that is real and it is the strongest argument. With the copy fixes of nimgrpc its bytes no longer cost more CPU than
  ZeroMQ's (the table above: 17% less for the series, faster from 64 KiB up), so the fallback path that carries artifact bytes through the core (the direct path of D-61 does not use this channel
  for bytes) is not a reason against it any more. Before the fixes it was about 7 times more.
* The core pays for connections: with the blocking server it is the number of threads (and about 0.25 MB each); the CPU per byte is no longer the problem. For a shard with many steps at once the blocking server is not a
  choice; the chronos one has to be tried, and that is a bigger piece of work than this move.
* Mutual TLS gives what CURVE did not: certificates with names and expiry, revocation by replacing the CA, standard tooling. It costs a certificate lifecycle.
