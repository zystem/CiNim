# Working on CiNim (notes for a coding session)

Read `README.md` first (what works, the structure, the build), then `docs/specification.md` for a requirement you touch (IDs like `PIP-012`, `DAT-003`, decisions `D-xx`).

## Rules of the project

- Tests first; the name of a test contains the ID of the requirement it verifies. Unit tests are `nimble test` (about 5 minutes); run a single file with
  `nim c -r --hints:off --warnings:off --outdir:build/tests tests/unit/<file>.nim`.
- Text in the repository is English. Docs and answers to the owner are in Russian; `docs-tr/` is the owner's gitignored Russian mirror of `docs/` (not in git: update it
  when a doc changes if it exists on your machine).
- The repository holds no private addresses, host names, cluster names or tokens: write "the TESTING cluster" in docs. Real values live in the owner's environment.
- Commit and push only when asked (a stop hook may ask for it). Never `pkill -f` (use `pkill -x name` or a PID). Never ask the owner to paste a token into the chat.
- The test cluster is for tests: anything may be created and deleted there. The owner decides what is a design change; a doubt about the design is a question, not a guess.
- Report what was checked and what was not. A claim about the code is checked in the code before it is made.

## Building

- Nim 2.2.4 (ORC), `nimble install -d`. System: libzmq, libsodium (`libsodium-dev`; tests of modules that import `src/common/sodiumaead.nim` link `-lsodium`), libpcre (the UI templates).
- `tests/unit/tkekclient_tls.nim.cfg` (`-d:ssl`) belongs to the TLS test; `tools/kekd-emu/certs.py` and `tls-front.py` need Python 3 with `cryptography` and `ssl`.
- The shim has two builds: without `-d:shimLogging` (no ZeroMQ, what the unit tests use) and with it (the real one). Check both: `nim check -d:shimLogging src/shim/shim.nim` and without.
- The job controller needs the Kubernetes C client (`-d:k8sPrefix=...`); without it use `nim check -d:k8sPrefix=/opt/k8s src/jobcontroller/main.nim` to type-check only.
- After a change to `proto/`: `tools/proto/nim_flatten.sh build/nimproto`.
- Images are built in the cluster with `REGISTRY=<host:port as the Pods reach it> TAG=<tag> tools/image/kaniko-build.sh` (both images; Kaniko runs as a build Pod, it needs a few minutes; the script's own
  `kubectl logs -f` may time out before the build ends: wait for the Pod `kaniko-images` in `cinim-build` to be `Succeeded`). Roll out: scale the executor to 0, `kubectl set image` for the core and the
  executor, `CINIM_CONTROLLER_IMAGE` on the core, the controller's image in the organisation's namespace, then the executor back to 1 (two executors on one run during a rollout cause trouble).

## Things that cost time (do not repeat)

- A segmentation fault with no trace in the shim or a thread: iterate a possibly-`nil` `JsonNode` only through `.elems` after a `kind` check. `for x in items(node)` always picks the iterator of `std/json`,
  whatever a function of your own with that name does. Build with `--stackTrace:on --lineTrace:on` and run the binary locally; it shows the line.
- `declared` is a magic of Nim: do not name a proc or a constant so. `func` cannot call `parseJson` (side effects): use `proc`.
- `std/net` `recv(pointer, size, timeout)` insists on all `size` bytes even on an unbuffered socket: wait with `poll` and `recv` without a timeout (`src/shim/artifacts.nim: readSome`).
- A string made in one thread and freed in another crashes tests that use threads: use fixed arrays for what crosses.
- Tools that write a file from itself (`open(p,'w').write(open(p).read())`) truncate it. Edit with a script that reads first, check `git diff --stat` before a commit.
- Integration tests (`CINIM_RQLITE_URL`) need a scratch rqlite: one node, 1Gi (`helm install rqlite rqlite/rqlite --version 2.0.0 --set replicaCount=1,persistence.size=1Gi`). Port-forward to the Pod (`pod/rqlite-0 24555:4001`), not to `svc/rqlite`: through the Service the requests hang.
- The kube API proxy eats the `Authorization` header: reach the core API through a port-forward or an Ingress.
- Kubernetes `exec` (the controller's spool fallback) goes through the API server; the controller has no direct channel to a step Pod.
- Do not use `.gitignore` patterns that can catch source files (`tests/**/t[!.]*[!.nim]` caught `*.nim.cfg`; there is a negation now).

## Where things are

- Core: `src/core` (API `api.nim`, scheduler, log collector, `artifactingest.nim`, `triggers.nim`, `secretvault.nim`, `objectstore.nim` + `storagebackend.nim` + `s3backend.nim`).
- Run volume (STO-001, D-47): `src/jobcontroller/runvolume.nim` (the claim and what a Pod gets of it), `src/core/runstorage.nim` (which runs' volumes may go), `cicd-shim --prepare-volume` (the init container).
- Shim: `src/shim` (`shim.nim`, `logclient.nim` for every call to the core, `artifacts.nim`). Controller: `src/jobcontroller`. Executor and Lua: `src/executorsvc`, `src/executor/bootstrap.lua`.
- Chart: `deploy/charts/cinim-shard`. Examples: `deploy/examples` (Garage, the key-service emulator, build Pods, self-build, the soak harness).
- Ports of the core: 18081 API, 19741 executor, 19742 step report, 19743 log ingest, 19744 artifact ingest, 19745 the push channel of the controllers (docs/conductors.md section 12).

## What is open (by priority)

1. The controller's drain of a kept Pod's artifacts through `exec` when the core orders it, and the core's order (the shim's side is built: manifest, `--read-artifact`, `--ack-artifacts`, exit 76).
2. The real key service (`kekd`) for the SmartCard-HSM 4K with an OMNIKEY 3121 reader: same protocol as the emulator (`docs/hardware-key.md`); first run `tools/hsm/card-check.sh` on the card.
3. Plain variables of the four levels (VAR-001), the log header of the effective values (VAR-005), the check of launch parameters at the API before a run exists (needs preflight, PIP-016).
4. Artifacts: a sweeper for retention and for abandoned multipart uploads, quotas per organisation, artifacts between runs, caches (DAT-004).
5. TLS and authentication of the registry and one registry name for the images; a deploy step; reproducible pinning; run cancellation (`concurrency: cancel_previous`).
6. UI tests (layer 1: render the Nimja templates and parse them with `nimquery`; Hurl against the server).
7. The 72-hour soak on the second test cluster: summarise with `tools/soak/summarize.sh` and record in `docs/specification.md` A.12 and `docs/threat-model.md` T-27.
