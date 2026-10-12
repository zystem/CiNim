# Working on CiNim (notes for a coding session)

Read `README.md` first (what works, the structure, the build), then `docs/specification.md` for a requirement you touch (IDs like `PIP-012`, `DAT-003`, decisions `D-xx`).

## Rules of the project

- Tests first; the name of a test contains the ID of the requirement it verifies. All unit and integration tests, in parallel, about 2 minutes: `tools/test/run.sh` (`-j 8` workers by default, more gains little; every worker has its own rqlite in a Docker container, made new at each run;
  `-u`/`-i` only unit/integration; `texec`, `tdrain`, `tm1skeleton` need the Kubernetes client and a cluster: name them on the command line). `nimble test` runs the unit tests in turn (about 5 minutes). Run a single file with
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
- Integration tests (`CINIM_RQLITE_URL`) need a scratch rqlite; `tools/test/run.sh` starts them in Docker (RAM-backed, faster than a port-forward). By hand: `docker run -d -p 127.0.0.1:24600:4001 --tmpfs /rqlite/file:rw,size=512m,mode=1777 rqlite/rqlite -fk -disco-mode=`. Against a cluster: one node, 1Gi (`helm install rqlite rqlite/rqlite --version 2.0.0 --set replicaCount=1,persistence.size=1Gi`) and a port-forward to the Pod (`pod/rqlite-0 24555:4001`), not to `svc/rqlite`: through the Service the requests hang. A test that makes tables of its own gives them its own names (`bench_...`): the schema's names belong to the other tests.
- The kube API proxy eats the `Authorization` header: reach the core API through a port-forward or an Ingress.
- Kubernetes `exec` (the controller's spool fallback) goes through the API server; the controller has no direct channel to a step Pod.
- After `helm upgrade` delete the conductor Pods only when the old controller Pods are gone from the list (`rollout status` answers while they still terminate and make a Pod from the old plan); from then on a conductor of another image is drained by the core by itself.
- Make every HTTP server with `newService` of `src/common/httpsrv.nim`, not with `newHttpServer`: GuildenStern 9.0.1 looks for `content-length: ` in the whole receive buffer of a thread, finds the header of an earlier POST behind the end of a shorter request and closes the connection, so a third of the connections were dropped after a few dozen POSTs (and `kubectl port-forward` died at the first). `tests/integration/thttp.nim` fails without the fix.
- A controller without an identity is refused by the core (T-46). A test that runs one (a poll, a stream report) sets `unenrolledControllers = true` after its imports, as `tstream.nim` does; a core started by a script sets `CINIM_UNENROLLED_CONTROLLERS=on`.
- Do not use `.gitignore` patterns that can catch source files (`tests/**/t[!.]*[!.nim]` caught `*.nim.cfg`; there is a negation now).

## Where things are

- Core: `src/core` (API `api.nim`, scheduler, log collector, `artifactingest.nim`, `triggers.nim`, `secretvault.nim`, `objectstore.nim` + `storagebackend.nim` + `s3backend.nim`).
- Run volume (STO-001, D-47): `src/jobcontroller/runvolume.nim` (the claim and what a Pod gets of it), `src/core/runstorage.nim` (which runs' volumes may go), `cicd-shim --prepare-volume` (the init container).
- Shim: `src/shim` (`shim.nim`, `logclient.nim` for every call to the core, `artifacts.nim`). Controller: `src/jobcontroller`. Lua: `src/executor` (sandbox, journal, replay, `bootstrap.lua`, the table of step numbers); the programs that run it: `src/conductor`.
- Conductor (docs/conductors.md, phases 2-3): `src/conductor/main.nim` (supervisor, and the run process with `--run`), `src/common/runpipe.nim`; its side in the core is in `streamhub.nim` and `scheduler.nim` (`leaseForConductor`). Started by hand (`/core conductor-credential <ns> <id>` gives its credential); the controller makes it when the shard has `CINIM_CONDUCTOR_IMAGE` (`src/jobcontroller/conductors.nim`). Build: `nim c -p:src --outdir:build -o:build/conductor src/conductor/main.nim`.
- Chart: `deploy/charts/cinim-shard`. Examples: `deploy/examples` (Garage, the key-service emulator, build Pods, self-build, the soak harness).
- Ports of the core: 18081 API, 19742 step report, 19743 log ingest, 19744 artifact ingest, 19745 the push channel of the controllers (docs/conductors.md section 12).

## What is open (by priority)

1. The controller's drain of a kept Pod's artifacts through `exec` when the core orders it, and the core's order (the shim's side is built: manifest, `--read-artifact`, `--ack-artifacts`, exit 76).
2. The real key service (`kekd`) for the SmartCard-HSM 4K with an OMNIKEY 3121 reader: same protocol as the emulator (`docs/hardware-key.md`); first run `tools/hsm/card-check.sh` on the card.
3. Variables of the levels group and project (VAR-001; the organisation's are built, docs/variables.md), the `env` of the pipeline and job in the precedence, the check of launch parameters at the API before a run exists (needs preflight, PIP-016).
4. Artifacts: a quota of bytes per organisation, a retention per organisation, a legal hold (DAT-006), artifacts between runs, caches (DAT-004). Built: the sweep of expired artifacts, abandoned uploads and orphans (`core/artifactsweep.nim`).
5. TLS and authentication of the registry and one registry name for the images; a deploy step; reproducible pinning; the cancel of a run by a newer run in a concurrency group of the script (PIP-014: `queue`, `cancel-oldest`, `cancel-newest`; for triggers `cancel_previous` and `skip` are built, TRG-004), the exception into `main` and `ci.finally` (RUN-006), the rest of the restart of failed steps (`:retry` is built for the same run with its volume; missing: a new run that refers to the old one, the stale rule, the UI choice, docs/parallel.md section 11).
6. UI tests (layer 1: render the Nimja templates and parse them with `nimquery`; Hurl against the server).
7. RBAC beyond the basic part (IAM-001, D-50, D-52): roles at the level of an organisation, groups, custom roles, OIDC, the export of the audit and a throttle of the login by address. Built: the audit log and the throttle by name (`core/audit.nim`). Check a running core with `tools/test/rbac-smoke.sh` (it changes the password of `admin` the first time; the administrator makes the users it tests with).
8. Compatibility code to delete when its condition is met: `docs/compat.md` (the list is the memory; strike a line in the commit that deletes the code).
