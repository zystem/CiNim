-- CiNim builds, tests and rolls itself out (D-42, D-47, D-48, D-63, D-82, D-107, D-109, D-110). This is the script of the repository: a trigger or a run names the repository and the commit and a conductor of
-- the organisation reads this file at that commit (`run.source`), so a change of the pipeline is a commit like any other. What it does is what the platform's helpers cannot know: which images, which tests, what
-- is rolled out. The rest is theirs: `j:checkout()` puts the commit in `src` (the mirror of the repository is a cache of the organisation), `j:image{...}` builds an image and pushes it (is it there already, tag the
-- image of the last good commit, copy to other registries, the login), `run.tag` is the tag, `run.source` the commit and the last good one.
--   1. `prep` (D-82): the commit checked out, the hashes of what the libraries and the tests images are made of, and the files that differ between the last good commit and this one,
--   2. `deps`: the image of the libraries (libsodium, nghttp2, the Kubernetes C client, the nimble packages; tools/image/Dockerfile.deps) as `cinim-deps:<hash>`, and the image of the tests
--      (tools/image/Dockerfile.test: Nim on glibc as on a workstation, the system libraries, the nimble packages and `rqlited`) as `cinim-test:<hash>`, each made once and found in the registry afterwards,
--   3. side by side, and the first failure stops the other: the images of the components (`ci.matrix`: each in a job of its own that checks the commit out and calls `j:image`; an image that nothing changed for is the
--      image of the last good commit under the new tag) and the tests (`tools/test/run.sh` in a Pod of the test image: the integration tests start their own `rqlited` processes, no Docker; `TEST_JOBS`
--      workers, `TEST` false leaves them out; the compiled C of the tests is a cache of the organisation (`nim-<hash>-<commit>`), so that only a first run compiles everything),
--   4. a deploy step (profile = DEPLOY_PROFILE, "platform": a deploy profile of the organisation (D-115), an ordinary, non-root Pod that may reach the Kubernetes API server with the token of its account, the rights of deployer.yaml) when DEPLOY is true: `helm upgrade --atomic --wait`
--      of the storage module and of the shard with the new tag of the images (the controllers and the conductors follow the core by themselves, D-62), a rollback of both releases to the
--      revisions they had if either fails, and a look at what runs afterwards.
-- D-82: what a commit changes decides what is done. The platform tells the script `run.source.base`, the commit of the last run of this pipeline on the same ref that ended OK and called `ci.verified()` (a new branch: on the default branch); the first job reduces the files that differ
-- between it and the commit to the areas of the tree and the changed test files, and this script decides (`plan` below): the images that must be built, and the tests that must run (those that import a
-- component that changed). With no base (a first run, a run whose script came in the request) or with no image of the base, everything is built and tested.
-- Start it with the commit to run, from a webhook (the trigger of the organisation names the repository; a git server calls it with {"commit": "<sha>"}), by the clock, or by hand:
--   POST /api/v1/runs  {"organization": "<slug>", "project": "<path>", "commit": "main", "params": {"REGISTRY": "<host[:port][/path] the build Pods push to>", "PULL_REGISTRY": "<the name the nodes pull from>"}}
-- Any registry that speaks the Docker registry API: the plain one of the cluster (the default: HTTP, no login), or one with TLS and a login (REGISTRY_INSECURE=false, REGISTRY_LOGIN=true): Gitea, GitHub
-- (ghcr.io/<owner>), GitLab, Docker Hub, Quay, Harbor, ... The images are `$REGISTRY/<image>`, so a registry that wants an owner or a project in the path has it in REGISTRY. The login is the Docker `config.json`
-- of the registry, the organisation's secret REGISTRY_DOCKER_CONFIG (docs/deployment.md "Where the images go"); PUSH_ALSO lists other registries that every image is copied to. The nodes pull with their own login (PULL_REGISTRY).
-- Leave TAG out and every run tags its images `run.tag`, <date>-<commit>. A run that came with the script in the request (no repository) takes REPO and REF from its parameters.
-- The organisation needs the build profile (build.enabled) with a build.egress rule for every registry, and a store for caches (the storage module); for the deploy step the deploy
-- profile (deploy.enabled, deploy.kubeApiServer, deploy.serviceAccount: the token of the Pod is the credential, its rights are deployer.yaml). A step that exits non-zero fails the job and so the run (6.7).
-- Parameters are plain environment variables of every step (VAR-002); the secrets are fetched by the shim and are never in the script.
local GIT = "alpine/git:v2.47.2"
local KUBECTL = "alpine/k8s:1.34.1"             -- kubectl, helm, git, jq
-- the images of the checks of tools/test/lint.sh, one tool each (none has bash: the script is POSIX sh); the pins are those of the tools run on the workstation
local SHELLCHECK = "koalaman/shellcheck-alpine:v0.11.0"
local HADOLINT = "hadolint/hadolint:v2.14.0-alpine"
local KUBECONFORM = "ghcr.io/yannh/kubeconform:v0.8.0-alpine"       -- the binary is /kubeconform and the image has no PATH to it

-- the component (tools/image/Dockerfile.<component>) and the image it is pushed as
local COMPONENTS = { { target = "core", image = "cinim" }, { target = "controller", image = "cinim-controller" },
                     { target = "conductor", image = "cinim-conductor" }, { target = "storage", image = "cinim-storage" },
                     { target = "ui", image = "cinim-ui" } }

-- What the checked-out commit says, returned to the script as outputs: DEPS (the hash of what the image of the libraries is made of: cinim.nimble, the script of the Kubernetes client and the Dockerfile), TESTDEPS
-- (cinim.nimble and the Dockerfile of the tests), HELMDEPS (Chart.lock), and what changed since BASE (D-82). The commit is in `src`, its history in `mirror.git` (`j:checkout()`).
local FACTS = [[
set -eu
deps=$(cat src/cinim.nimble src/tools/k8s/build_client.sh src/tools/image/Dockerfile.deps | sha256sum | cut -c1-16)
tests=$(cat src/cinim.nimble src/tools/image/Dockerfile.test | sha256sum | cut -c1-16)
helm=$(sha256sum < src/deploy/charts/cinim-shard/Chart.lock | cut -c1-16)
# D-82: the files that differ between BASE (the last good commit, told by the platform) and the commit, reduced to the areas of the tree (`src/core`, `docs`, ...) and the changed test files: what the
# script decides by. Without a usable BASE nothing is said and the script builds and tests everything.
base="${BASE:-}"
printf '%s' "$base" | grep -Eq '^[0-9a-f]{40}$' || base=""
[ -z "$base" ] || git -C mirror.git fetch -q "$REPO" "$base" 2>/dev/null || base=""
areas=""; ctests=""
if [ -n "$base" ]; then
  if changed=$(git -C mirror.git diff --name-only "$base" "$SHA"); then
    areas=$(printf '%s\n' "$changed" | awk -F/ 'NF == 0 {next} NF == 1 {print $1; next} $1 == "src" || $1 == "tests" {print $1 "/" $2; next} $1 == "tools" && $2 == "image" {print $1 "/" $2 "/" $3; next} $1 == "tools" {print $1 "/" $2; next} {print $1}' | sort -u | paste -sd, -)
    ctests=$(printf '%s\n' "$changed" | grep -E '^tests/(unit|integration|contract)/t[^/]*\.nim(\.cfg)?$' | sed 's/\.cfg$//' | sort -u | paste -sd, - || true)
    [ ${#ctests} -le 1500 ] || ctests=all
  else base=""; fi
fi
echo "changed since ${base:-nothing known}: ${areas:-nothing}"
{ echo "DEPS=$deps"; echo "TESTDEPS=$tests"; echo "HELMDEPS=$helm"
  echo "BASE=${base:-none}"; echo "AREAS=${areas:-none}"; echo "CHANGED_TESTS=${ctests:-none}"; } >> "$CICD_OUTPUT"
]]

-- The tests, in a Pod: the integration tests start `rqlited` themselves (tools/test/run.sh), the unit tests need nothing. The nimble packages of the image are in the home of root, which is what
-- the build profile gives a step (root of a user namespace of its own); the cache of the compiler is in the volume of the job, where the organisation's cache puts it.
-- tools/test/lint.sh in the image of its tool (LINT_REQUIRE: a tool that is missing is a failure, not a skipped check). The charts are rendered by the first step into `rendered` of the workspace, the second step
-- (the image of kubeconform, which has the Kubernetes schemas' address in its egress: raw.githubusercontent.com) checks what is there. The subcharts of the shard come from the cache that the deploy step uses.
local LINT_SHELL = "set -eu\nLINT_REQUIRE=1 sh src/tools/test/lint.sh shell"
local LINT_DOCKER = "set -eu\nLINT_REQUIRE=1 sh src/tools/test/lint.sh docker"
local LINT_HELM = [[
set -eu
mkdir -p src/deploy/charts/cinim-shard/charts && cp -r charts-cache/. src/deploy/charts/cinim-shard/charts/
LINT_REQUIRE=1 LINT_RENDER="$PWD/rendered" sh src/tools/test/lint.sh helm
]]
local LINT_KUBECONFORM = "set -eu\nPATH=/:$PATH LINT_REQUIRE=1 LINT_RENDER=\"$PWD/rendered\" sh src/tools/test/lint.sh kubeconform"

-- The ASan run (parameter ASAN; a schedule trigger with ASAN=true makes it nightly): the files that start threads and talk over the push channel, built with AddressSanitizer on the system allocator
-- (tools/test/run.sh, CINIM_TEST_ASAN). A use after free there (the client closed its channel under its reader) showed as a hang now and then, and as the whole corrupted heap, not as a report; with ASan it is
-- a report at once. The conductor test starts a binary of the conductor that is not built with ASan and is left out.
local ASAN_TESTS = [[
set -eu
cd src
export XDG_CACHE_HOME=/cicd/workspace/nimcache TMPDIR=/cicd/workspace/tmp; mkdir -p "$XDG_CACHE_HOME" "$TMPDIR"
tools/proto/nim_flatten.sh build/nimproto
for v in $(env | grep -o '^CICD_[A-Z_]*'); do unset "$v"; done
rc=0
CINIM_TEST_ASAN=1 CINIM_TEST_NICE=10 CINIM_RQLITE_BIN="$(command -v rqlited)" tools/test/run.sh -j "${TEST_JOBS:-2}" tests/unit/tstream.nim tests/integration/tstream.nim tests/integration/tconductorhub.nim || rc=$?
for log in $(grep '^FAIL' build/test-logs/summary.txt 2>/dev/null | sed 's/.*(\(.*\))$/\1/'); do echo "=== $log"; tail -n 40 "$log"; done
exit $rc
]]

-- The soak (NFR-013, tools/soak/run72.sh: the release harness continuously and the ASan/LSan harness in hourly runs; parameter SOAK, a schedule trigger makes it weekly): one step in the image built from
-- tools/soak/Dockerfile, as long as the hours say (72). A step may be as long as a week, and the shard's default is 24 h (the project's max_step_timeout_seconds must allow it: docs/deployment.md, "The 72 h soak"). The step fails when the release
-- run does not end with `SOAK OK` (RSS growth after the warm-up within 2 %) or an ASan hour does not end well, and its log is the report.
local SOAK_RUN = [[
set -eu
cd /cinim
OUT=/cicd/workspace/soak-out; mkdir -p "$OUT"
rc=0
FOREGROUND=1 tools/soak/run72.sh "$OUT" "$SOAK_HOURS" || rc=$?
tools/soak/summarize.sh "$OUT" || true
echo "== the release run, one row an hour"; awk -F, 'NR == 1 || (NR - 1) % 60 == 0' "$OUT/release.csv" || true
last=$(tail -n 1 "$OUT/release.out" 2>/dev/null || true)
echo "release run: ${last:-no output}"
case "$last" in "SOAK OK"*) ;; *) echo "the release run did not end with SOAK OK"; rc=1;; esac
bad=$(grep '^hour ' "$OUT/san-summary.txt" 2>/dev/null | grep -vc 'exit=0$' || true)
[ "${bad:-0}" = 0 ] || { echo "$bad ASan hours did not end well"; rc=1; }
exit $rc
]]

local TESTS = [[
set -eu
cd src
# What fsyncs is slow on the disks of a node (76 ms on the root file system, 1.4 to 160 ms on the volume of the job, measured: the databases of the tests took 43 s to answer once), so
# the databases of the tests are in /dev/shm, which the job asked to be in memory (`shm`; tools/test/run.sh uses it when it has the room); the compiler's cache and the other
# temporary files are on the volume of the job.
export XDG_CACHE_HOME=/cicd/workspace/nimcache TMPDIR=/cicd/workspace/tmp; mkdir -p "$XDG_CACHE_HOME" "$TMPDIR"
tools/proto/nim_flatten.sh build/nimproto
# the Caddy node of the HTTP store is in the image: the tests that start nodes look for it as build/caddy-store (they are skipped without it)
mkdir -p build; [ ! -x /usr/local/bin/caddy-store ] || ln -sf /usr/local/bin/caddy-store build/caddy-store
for v in $(env | grep -o '^CICD_[A-Z_]*'); do unset "$v"; done         # this is a step of a run, and the tests are about shims that make their own
rc=0
# D-82: when the script decided on some of the tests (COMPONENTS: what changed and what imports it), those that import one of them and the test files that changed; else all of them
files=""
if [ -n "${COMPONENTS:-}${CHANGED_TESTS:-}" ]; then
  pat=$(printf '%s' "${COMPONENTS:-nothing-at-all}" | tr ',' '|')
  files=$({ grep -lE "(^|[^A-Za-z0-9_])($pat)/" tests/unit/t*.nim tests/integration/t*.nim tests/contract/t*.nim || true
            for t in $(printf '%s' "${CHANGED_TESTS:-}" | tr ',' ' '); do [ -f "$t" ] && echo "$t"; done; } | grep -v -e tm1skeleton -e thsperf | sort -u || true)
  [ -n "$files" ] || { echo "no test imports what changed: none is run"; exit 0; }
  echo "the tests that import what changed:"; echo "$files"
fi
# the compilers and the tests are niced: on a busy node the databases of the tests starve otherwise (a query waited 15 s)
CINIM_REQUIRE_BUF=1 CINIM_TEST_DBPROBE=1 CINIM_TEST_NICE=10 CINIM_RQLITE_BIN="$(command -v rqlited)" tools/test/run.sh -j "${TEST_JOBS:-2}" $files || rc=$?
# the tail of the log of every file that failed, so that the log of the step says why
for log in $(grep '^FAIL' build/test-logs/summary.txt 2>/dev/null | sed 's/.*(\(.*\))$/\1/'); do echo "=== $log"; tail -n 30 "$log"; done
exit $rc
]]

-- Rolling the core out is helm's: both releases at the new tag, atomic and waiting for the readiness probes of the Pods (/readyz of the core and of the module); if either fails both are
-- brought back to the revision they had. The controllers and the conductors follow the core by themselves: the core replaces a controller of another image and drains a conductor of another image (D-62).
-- The subcharts of the shard chart (rqlite, VictoriaLogs) are not in the repository (their archives are ignored by git) and the deploy profile reaches nothing but the API server: a job of the build
-- profile fetches them once for a lock (`helm dependency build`) and keeps them as a cache of the organisation, the deploy job restores that.
local HELM_DEPS = [=[
set -eu
[ -d charts-cache ] && exit 0
export HELM_CACHE_HOME=$PWD/.helm/cache HELM_CONFIG_HOME=$PWD/.helm/config HELM_DATA_HOME=$PWD/.helm/data
cd src
# the repositories of the subcharts are named by URL in Chart.yaml and must be known to helm before it fetches from them (not the file:// one of hsmgate: helm has no handler to add it, and builds it from the path)
for u in $(grep -h '^[[:space:]]*repository:' deploy/charts/cinim-shard/Chart.yaml | awk '{print $2}' | grep -v '^file://' | sort -u); do helm repo add "r$(printf %s "$u" | cksum | cut -d' ' -f1)" "$u" >/dev/null; done
helm dependency build deploy/charts/cinim-shard >/dev/null
cp -r deploy/charts/cinim-shard/charts ../charts-cache
]=]

-- The core's own restart ends the Pod that this step runs next to, and the step's result is delivered to the new core when it is up (the shim keeps trying).
local ROLLOUT = [[
set -eu
# the credential is the Pod's own token (D-48, deploy.serviceAccount of the shard): helm and kubectl read it as the in-cluster configuration, whose namespace is that of the Pod, not the shard's
kubectl() { command kubectl -n "$NAMESPACE" "$@"; }
pull=${PULL_REGISTRY:-$REGISTRY}               # the name the nodes pull the images by (the parameter is empty when it is the one the build pushes to)
mkdir -p src/deploy/charts/cinim-shard/charts
cp -r charts-cache/. src/deploy/charts/cinim-shard/charts/               # the subcharts that the job of the build profile fetched
cd src
revision() { helm history "$1" -n "$NAMESPACE" --max 1 -o json | jq -r '.[0].revision'; }
shard_was=$(revision "$RELEASE"); storage_was=$(revision "$STORAGE_RELEASE")
back() {
  echo "the rollout failed: bringing both releases back (shard revision $shard_was, storage revision $storage_was)" >&2
  helm rollback "$STORAGE_RELEASE" "$storage_was" -n "$NAMESPACE" --wait --timeout 5m || true
  helm rollback "$RELEASE" "$shard_was" -n "$NAMESPACE" --wait --timeout 5m || true
  exit 1
}
# the repository is set too: the values a release was made with can name a registry that is gone (the storage release did), and `--reset-then-reuse-values` keeps them
helm upgrade "$STORAGE_RELEASE" deploy/charts/cinim-storage -n "$NAMESPACE" --reset-then-reuse-values --set image.repository="$pull/cinim-storage" --set image.tag="$IMAGE_TAG" --atomic --wait --timeout 10m || back
helm upgrade "$RELEASE" deploy/charts/cinim-shard -n "$NAMESPACE" --reset-then-reuse-values --set image.repository="$pull/cinim" --set image.tag="$IMAGE_TAG" --atomic --wait --timeout 10m || back
# what runs now: the core and the module are at the tag, and ready
for d in cinim-core cinim-storage; do
  img=$(kubectl get deploy "$d" -o jsonpath='{.spec.template.spec.containers[0].image}')
  ready=$(kubectl get deploy "$d" -o jsonpath='{.status.readyReplicas}')
  case "$img" in *":$IMAGE_TAG") ;; *) echo "$d runs $img, not $IMAGE_TAG" >&2; back;; esac
  [ "${ready:-0}" -ge 1 ] || { echo "$d has no ready replica" >&2; back; }
done
echo "rolled out $IMAGE_TAG: shard revision $(revision "$RELEASE"), storage revision $(revision "$STORAGE_RELEASE")"
]]

-- D-82: what a commit changes, and so what is done. The components are the directories of src/ and each is made of itself and what it imports (tests/unit/tboundaries.nim keeps this table equal to the
-- imports). `areas` are what the first job found changed: `src/<component>`, `proto`, `lua`, `docs`, `tools/image/Dockerfile.<x>`, a file of the top directory, ... A path that is not known is "everything":
-- a wrong guess toward more work is safe, toward less is not.
local DEPENDS = { common = {}, shim = {"common"}, jobcontroller = {"common"}, conductor = {"common", "executor"}, executor = {"common"}, core = {"common", "executor"}, storage = {"common"}, ui = {"common"}, router = {"common", "ui"} }
local IMAGE_PARTS = { core = {"core"}, controller = {"jobcontroller", "shim"}, conductor = {"conductor"}, storage = {"storage"}, ui = {"ui"} }   -- the components of src/ that an image is made of
local SPEAK_PROTO = { core = true, controller = true, conductor = true }     -- the images that have the types of the messages
local RUN_LUA = { core = true, conductor = true }                            -- the images that run Lua and have its stubs
local BUILD_ALL = { ["cinim.nimble"] = true, ["config.nims"] = true, ["nim.cfg"] = true, ["tools/image/build-static.sh"] = true, ["tools/image/Dockerfile.deps"] = true,
                    ["tools/k8s"] = true, ["tools/proto"] = true, ["tools/shim"] = true, ["tools/grpc"] = true }        -- the build of everything
local TESTS_ALL = { ["tests/support"] = true, ["tests/certs"] = true, ["tests/vectors"] = true, ["tests/contract"] = true, ["tools/test"] = true, [".ci"] = true, ["deploy"] = true,
                    ["tools/image/Dockerfile.test"] = true }                     -- what every test may depend on, and not an image
local NOTHING = { docs = true, ["docs-tr"] = true, [".claude"] = true, [".gitignore"] = true, LICENSE = true }       -- changes that no image and no test depends on

local function list_of(text)
  local t = {}
  if text and text ~= "none" then for x in string.gmatch(text, "[^,]+") do t[#t + 1] = x end end
  return t
end

-- from the areas (and the changed test files) to what is built and run. `images`: name -> true; `tests`: "all", "none" or "some" with `components` (the changed ones and what imports them, a comma list)
-- and `changed_tests`. Nothing changed (the base is the commit itself) is nothing built and nothing run.
local function plan(areas_text, changed_tests_text)
  local areas = list_of(areas_text)
  local out = { images = {}, tests = "none", components = "", changed_tests = (changed_tests_text and changed_tests_text ~= "none") and changed_tests_text or "" }
  local all_images = { core = true, controller = true, conductor = true, storage = true, ui = true }
  local changed, everything, tests_all, test_files = {}, false, false, false
  local dockerfile, proto, lua = {}, false, false
  for _, a in ipairs(areas) do
    local comp = a:match("^src/(.+)$")
    local image = a:match("^tools/image/Dockerfile%.(%w+)$")
    if comp and DEPENDS[comp] then changed[comp] = true
    elseif a == "proto" then proto = true
    elseif a == "lua" then lua = true
    elseif BUILD_ALL[a] then everything = true
    elseif image and all_images[image] then dockerfile[image] = true
    elseif TESTS_ALL[a] then tests_all = true
    elseif a == "tests/unit" or a == "tests/integration" then test_files = true
    elseif NOTHING[a] or a:match("%.md$") or a == "tools/image/Dockerfile.caddy-store" or a == "tools/image/Dockerfile.local" then -- nothing depends on it
    else everything = true end                                        -- not known
  end
  -- the images: a component of it changed (or one it imports), the proto for the three that have the types, the Lua stubs for the two that run Lua, its own Dockerfile
  local function closure(c, into)
    into[c] = true
    for _, d in ipairs(DEPENDS[c]) do closure(d, into) end
    return into
  end
  for name, parts in pairs(IMAGE_PARTS) do
    local hit = everything or dockerfile[name] or (proto and SPEAK_PROTO[name]) or (lua and RUN_LUA[name])
    for _, part in ipairs(parts) do
      for c in pairs(closure(part, {})) do if changed[c] then hit = true end end
    end
    if hit then out.images[name] = true end
  end
  -- the tests: all of them when what every test depends on changed (common is in all of them), none when only what no test depends on did, else those that import what changed
  local comps = {}
  for c in pairs(DEPENDS) do
    for d in pairs(closure(c, {})) do if changed[d] then comps[#comps + 1] = c; break end end
  end
  table.sort(comps)
  if everything or tests_all or proto or lua or changed.common then out.tests = "all"
  elseif #comps > 0 or (test_files and out.changed_tests ~= "") then
    out.tests = "some"
    out.components = table.concat(comps, ",")
  end
  if out.changed_tests == "all" then out.tests = "all" end
  return out
end

return ci.pipeline({
  name = "cinim-self-build",
  params = {
    REGISTRY = ci.string{required = true, max_length = 200},                          -- host[:port][/path], as the build Pods reach the registry; the images are $REGISTRY/<image>
    REGISTRY_INSECURE = ci.bool{default = true},                                      -- the registry speaks plain HTTP or has no certificate to check (the registry of the cluster); false for TLS
    PUSH_ALSO = ci.string{default = "", max_length = 500},                            -- other registries the images are copied to, host[:port][/path], separated by commas (the same names and tags)
    REGISTRY_LOGIN = ci.bool{default = false},                                        -- the steps that talk to the registry log in with the secret REGISTRY_DOCKER_CONFIG (the text of a Docker config.json)
    PULL_REGISTRY = ci.string{default = "", max_length = 200},                        -- the name the nodes pull the images from; empty: the same as REGISTRY
    TAG = ci.string{default = "", max_length = 100, pattern = "[%w%._%-]*"},          -- the tag of the images; empty: run.tag (<date>-<commit>)
    REPO = ci.string{default = "https://github.com/zystem/CiNim.git", max_length = 300},   -- when the run did not come from a repository (run.source)
    REF = ci.string{default = "main", max_length = 100, pattern = "[%w%._%-/]+"},     -- a branch, a tag or a SHA; the same
    NAMESPACE = ci.string{default = "cinim-001", max_length = 63},                    -- the namespace of the shard that is rolled out
    RELEASE = ci.string{default = "cinim-001", max_length = 53},                      -- the Helm release of the shard
    STORAGE_RELEASE = ci.string{default = "cinim-storage", max_length = 53},          -- the Helm release of the storage module
    BUILD = ci.bool{default = true},
    TEST = ci.bool{default = true},
    ASAN = ci.bool{default = false},                                                  -- the files of the push channel under AddressSanitizer (a schedule trigger sets it for the nightly run); needs vm.mmap_rnd_bits <= 28 on the nodes
    SOAK = ci.bool{default = false},                                                  -- the 72 h soak (NFR-013) as one step; a schedule trigger sets it for the weekly run (with BUILD, TEST, LINT false); the project must allow a step this long
    SOAK_HOURS = ci.number{default = 72, min = 1, max = 72, integer = true},          -- how long the soak runs (the step's timeout is these hours and eight more)
    LINT = ci.bool{default = true},                                                   -- shellcheck, hadolint, helm lint and kubeconform (tools/test/lint.sh), each in the image of its tool, side by side with the tests
    TEST_JOBS = ci.number{default = 2, min = 1, max = 16, integer = true},            -- workers of tools/test/run.sh in the Pod (a compile takes a gigabyte or two)
    BUILD_JOBS = ci.number{default = 2, min = 1, max = 4, integer = true},            -- images built at a time (each is a Kaniko Pod with its own volume; a small cluster cannot take four and a test run)
    DEPLOY = ci.bool{default = false},
    DEPLOY_PROFILE = ci.string{default = "platform", max_length = 40},                -- the deploy profile of the organisation whose account (and token) the rollout uses (D-115, deployer.yaml)
  },
  main = function(run)
    local p = run.params
    local pull = (p.PULL_REGISTRY ~= "") and p.PULL_REGISTRY or p.REGISTRY
    -- where the commit is: the repository and the commit that the conductor read this script from, or the parameters
    local repo = (run.source.repository ~= "") and run.source.repository or p.REPO
    local ref = (run.source.commit ~= "") and run.source.commit or p.REF
    local also = {}
    for r in p.PUSH_ALSO:gmatch("[^,%s]+") do also[#also + 1] = r end
    local info
    -- a job in a volume of its own with the commit checked out in `src`; its steps are `fn`'s
    local function checked_out(id, env, fn, opts)
      opts = opts or {}
      ci.single[id]{ image = opts.image or GIT, profile = opts.profile or "build", workspace = "isolated", env = env, timeout = opts.timeout, secrets = opts.secrets, shm = opts.shm, body = function(j)
        j:checkout{ url = repo, ref = info.SHA }
        fn(j)
      end }
    end
    -- the options of an image that are the same for all of them
    local function image(name, dockerfile, tag, more)
      local o = { name = name, registry = p.REGISTRY, dockerfile = dockerfile, tag = tag, insecure = p.REGISTRY_INSECURE, login = p.REGISTRY_LOGIN }
      for k, v in pairs(more or {}) do o[k] = v end
      return o
    end
    -- 1. the commit, and what it says (the mirror of the repository is a cache of the organisation: the first run fetches everything, the next ones what is new)
    ci.single['p']{ image = GIT, profile = "build", workspace = "isolated", env = { REPO = repo, BASE = run.source.base }, body = function(j)
      local co = j:checkout{ url = repo, ref = ref }
      info = j:run(step.sh['1']{ cmd = FACTS, env = { SHA = co.commit } }).outputs
      info.SHA = co.commit
      if not (info.DEPS and info.TESTDEPS and info.HELMDEPS) then error("no commit found for " .. ref) end
    end }
    local tag = p.TAG
    if tag == "" then tag = (run.source.short ~= "") and run.tag or (run.tag .. "-" .. info.SHA:sub(1, 7)) end
    -- D-82: the images that are built (the others are the image of BASE under the new tag) and whether the tests run at all
    local base = (info.BASE and info.BASE ~= "none") and info.BASE or ""
    local decided
    if base == "" then   -- nothing is known of the last good commit: everything is built and tested
      decided = { images = { core = true, controller = true, conductor = true, storage = true, ui = true }, tests = "all", components = "", changed_tests = "" }
    else
      decided = plan(info.AREAS, info.CHANGED_TESTS)
    end
    local affected = decided.images
    local run_tests = p.TEST and decided.tests ~= "none"
    local env = { SHA = info.SHA, IMAGE_TAG = tag, DEPS = info.DEPS, TESTDEPS = info.TESTDEPS, TEST_JOBS = tostring(p.TEST_JOBS), BASE = base,
                  COMPONENTS = (decided.tests == "some") and decided.components or "", CHANGED_TESTS = (decided.tests == "some") and decided.changed_tests or "" }
    if p.BUILD or run_tests or p.LINT or p.ASAN then
      -- 2. the libraries, and the tests' image, once for as long as what they are made of stays the same
      if p.BUILD then
        checked_out('d', env, function(j) j:image(image("cinim-deps", "tools/image/Dockerfile.deps", info.DEPS, { skip_if_present = true })) end)
      end
      if run_tests or p.ASAN then
        checked_out('t', env, function(j) j:image(image("cinim-test", "tools/image/Dockerfile.test", info.TESTDEPS, { skip_if_present = true })) end)
      end
      -- 3. the images of the components, and the tests, side by side: the first that fails stops the others
      local names, by, number = {}, {}, {}
      for i, c in ipairs(COMPONENTS) do names[#names + 1] = c.target; by[c.target] = c; number[c.target] = i end
      local branches = {}
      if p.BUILD then
        branches.images = function()
          ci.parallel(ci.matrix{axes = {component = names}, fail_fast = true, max_parallel = p.BUILD_JOBS}, function(c)
            local comp = by[c.component]
            checked_out(b32f("{xx}", 32 + number[comp.target]), env, function(j)         -- the jobs 11, 12, ... one for each component
              j:image(image(comp.image, "tools/image/Dockerfile." .. comp.target, tag, {
                build_args = { DEPS_IMAGE = p.REGISTRY .. "/cinim-deps:" .. info.DEPS },
                -- nothing of it changed since BASE: the image of BASE under the new tag; if the registry has none, it is built
                reuse = (not affected[comp.target] and base ~= "") and { suffix = "-" .. base:sub(1, 7) } or nil,
                also = also }))
            end)
          end)
        end
      end
      if run_tests then
        branches.tests = function()
          local key = "nim-" .. info.TESTDEPS .. "-"
          checked_out('v', env, function(j)
            j:run(step.cache_restore['3']{ keys = {"nim-none", key} })   -- the C the tests were compiled to by an earlier run: the next run compiles what changed (the first key is exact, the others are prefixes: `key` alone matched nothing, and every run compiled everything)
            local ok, err = pcall(function() j:run(step.sh['4']{ cmd = TESTS }) end)
            j:run(step.cache_save['5']{ key = key .. info.SHA, paths = {"nimcache"} })          -- also after a failed run: the compiling is what took the time, and it was done
            if not ok then error(err, 0) end
          end, {image = pull .. "/cinim-test:" .. info.TESTDEPS, timeout = "120m", shm = "1Gi"})      -- the databases of the tests are in memory: the disks of a node fsync in 1 ms or in 160
        end
      end
      if p.ASAN then
        branches.asan = function()
          checked_out('z', env, function(j) j:run(step.sh['4']{ cmd = ASAN_TESTS }) end,
                      {image = pull .. "/cinim-test:" .. info.TESTDEPS, timeout = "60m", shm = "1Gi"})
        end
      end
      if p.LINT then
        branches.lint = function()
          ci.parallel({
            shell = function() checked_out('w', env, function(j) j:run(step.sh['1']{ cmd = LINT_SHELL, image = SHELLCHECK }) end) end,
            docker = function() checked_out('x', env, function(j) j:run(step.sh['1']{ cmd = LINT_DOCKER, image = HADOLINT }) end) end,
            helm = function()
              local helm_key = "helm-" .. info.HELMDEPS
              checked_out('y', env, function(j)
                j:run(step.cache_restore['3']{ keys = {helm_key} })
                j:run(step.sh['4']{ cmd = HELM_DEPS, image = KUBECTL })
                pcall(function() j:run(step.cache_save['5']{ key = helm_key, paths = {"charts-cache"} }) end)       -- there already for this lock: nothing to keep
                j:run(step.sh['6']{ cmd = LINT_HELM, image = KUBECTL })
                j:run(step.sh['7']{ cmd = LINT_KUBECONFORM, image = KUBECONFORM })
              end)
            end,
          })       -- all three are reported: a failed one does not cancel the others
        end
      end
      ci.parallel(branches, {fail_fast = true})
    end
    -- the soak: the image of the harness, built for this commit, then the run (one step, 80 h at most here)
    if p.SOAK then
      checked_out('q', env, function(j) j:image(image("cinim-soak", "tools/soak/Dockerfile", tag, {})) end)
      ci.single['s']{ image = pull .. "/cinim-soak:" .. tag, profile = "default", workspace = "isolated", env = { SOAK_HOURS = tostring(p.SOAK_HOURS) },
                      timeout = tostring(p.SOAK_HOURS + 8) .. "h", body = function(j)
        j:run(step.sh['1']{ cmd = SOAK_RUN })
      end }
    end
    -- D-112: built (or tagged from the base) and tested (or nothing changed that a test covers): this commit is a base for the runs that come after, on this ref
    if p.BUILD and p.TEST then ci.verified() end
    -- 4. the new tag in the cluster
    if p.DEPLOY then
      local helm_key = "helm-" .. info.HELMDEPS
      checked_out('h', env, function(j)
        j:run(step.cache_restore['3']{ keys = {helm_key} })
        j:run(step.sh['4']{ cmd = HELM_DEPS })
        pcall(function() j:run(step.cache_save['5']{ key = helm_key, paths = {"charts-cache"} }) end)       -- there already for this lock: nothing to keep
      end, {image = KUBECTL})
      checked_out('r', env, function(j)
        j:run(step.cache_restore['3']{ keys = {helm_key} })
        j:run(step.sh['4']{ cmd = ROLLOUT })
      end, {image = KUBECTL, profile = p.DEPLOY_PROFILE})
    end
    return tag
  end,
})
