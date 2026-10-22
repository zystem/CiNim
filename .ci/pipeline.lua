-- CiNim builds, tests and rolls itself out (D-42, D-47, D-48, D-63). This is the script of the repository: a trigger or a run names the repository and the commit and a conductor of the
-- organisation reads this file at that commit (`run.source`), so a change of the pipeline is a commit like any other.
--   1. `prep`: fetch the repository into a bare mirror kept as a cache of the organisation (`git-<commit>`, docs/cache.md; the next run fetches only what is new), find the commit,
--      the tag of the images and the hash of what the libraries image is made of,
--   2. `deps`: the image of the libraries (libsodium, libzmq, the Kubernetes C client, the nimble packages; tools/image/Dockerfile.deps) as `cinim-deps:<hash>`, and the image of the tests
--      (tools/image/Dockerfile.test: Nim on glibc as on a workstation, the system libraries, the nimble packages and `rqlited`) as `cinim-test:<hash>`, each made once and found in the registry afterwards,
--   3. side by side, and the first failure stops the other: the images of the components (`ci.matrix`: each build restores the mirror of its commit, clones from it into its own volume and runs
--      Kaniko on the Dockerfile of its component with DEPS_IMAGE) and the tests (`tools/test/run.sh` in a Pod of the test image: the integration tests start their own `rqlited` processes,
--      no Docker; `TEST_JOBS` workers, `TEST` false leaves them out; the compiled C of the tests is a cache of the organisation (`nim-<hash>-<commit>`), so that only a first run compiles everything),
--   4. a deploy step (profile = "deploy": an ordinary, non-root Pod that may reach the Kubernetes API server with the token of deployer.yaml) when DEPLOY is true: `helm upgrade --atomic --wait`
--      of the storage module and of the shard with the new tag of the images (the controllers and the conductors follow the core by themselves, D-62), a rollback of both releases to the
--      revisions they had if either fails, and a look at what runs afterwards.
-- Start it with the commit to run, from a webhook (the trigger of the organisation names the repository; a git server calls it with {"commit": "<sha>"}), by the clock, or by hand:
--   POST /api/v1/runs  {"organization": "<slug>", "repository": "https://github.com/zystem/CiNim.git", "commit": "main",
--                       "params": {"REGISTRY": "<host:port the build Pods push to>", "PULL_REGISTRY": "<the name the nodes pull from>"}}
-- Leave TAG out and every run tags its images <date>-<commit>. A run that came with the script in the request (no repository) takes REPO and REF from its parameters.
-- The organisation needs the build profile (build.enabled) with a build.egress rule for the registry, and a store for caches (the storage module); for the deploy step the deploy
-- profile (deploy.enabled, deploy.kubeApiServer) and the secrets DEPLOY_TOKEN and DEPLOY_CA (deployer.yaml). A step that exits non-zero fails the job and so the run (6.7).
-- Parameters are plain environment variables of every step (VAR-002); the secrets are fetched by the shim and are never in the script.
local KANIKO = "ghcr.io/osscontainertools/kaniko:v1.28.5-debug@sha256:d6d74217dc077acfd3094992e917c357080a2d3fdd1042a49e34e29a7e57c572"
local GIT = "alpine/git:v2.47.2"
local KUBECTL = "alpine/k8s:1.34.1"             -- kubectl, helm, git, jq

-- the component (tools/image/Dockerfile.<component>) and the image it is pushed as
local COMPONENTS = { { target = "core", image = "cinim" }, { target = "controller", image = "cinim-controller" },
                     { target = "conductor", image = "cinim-conductor" }, { target = "storage", image = "cinim-storage" },
                     { target = "ui", image = "cinim-ui" } }

-- the mirror, the commit and the hashes, returned to the script as outputs: SHA, TAG, DEPS (the hash of the stage of the libraries, cinim.nimble and the script of the Kubernetes client) TESTDEPS (cinim.nimble and the Dockerfile of the tests) and HELMDEPS (the lock of the subcharts of the shard chart)
local PREP = [[
set -eu
[ -f mirror.git/HEAD ] || git init -q --bare mirror.git
if printf '%s' "$REF" | grep -Eq '^[0-9a-f]{40}$'; then
  git -C mirror.git fetch -q "$REPO" "$REF"                  # a commit by its SHA (what a webhook or `run.source` gives)
else
  git -C mirror.git fetch -q "$REPO" "+refs/heads/$REF:refs/heads/$REF" || git -C mirror.git fetch -q "$REPO" "+refs/tags/$REF:refs/tags/$REF"
fi
sha=$(git -C mirror.git rev-parse "$REF^{commit}")
deps=$({ git -C mirror.git show "$sha:cinim.nimble"; git -C mirror.git show "$sha:tools/k8s/build_client.sh"; git -C mirror.git show "$sha:tools/image/Dockerfile.deps"; } | sha256sum | cut -c1-16)
tests=$({ git -C mirror.git show "$sha:cinim.nimble"; git -C mirror.git show "$sha:tools/image/Dockerfile.test"; } | sha256sum | cut -c1-16)
helm=$(git -C mirror.git show "$sha:deploy/charts/cinim-shard/Chart.lock" | sha256sum | cut -c1-16)
{ echo "SHA=$sha"; echo "TAG=${TAG:-$(date -u +%Y%m%d)-$(echo "$sha" | cut -c1-7)}"; echo "DEPS=$deps"; echo "TESTDEPS=$tests"; echo "HELMDEPS=$helm"; } >> "$CICD_OUTPUT"
]]

-- the source of the commit in the volume of the job: from the mirror that the cache gave, the files written by one worker (checkout.workers=0 was the fastest, docs/storage-module.md)
local CLONE = [[
set -eu
git clone -q -n --shared mirror.git src
git -C src -c advice.detachedHead=false -c checkout.workers=0 checkout -q "$SHA"
]]

local REGISTRY_FLAGS = "--insecure --insecure-pull --skip-tls-verify --skip-tls-verify-pull"
local function kaniko(component, image, tag, extra)
  return "/kaniko/executor --dockerfile=/cicd/workspace/src/tools/image/Dockerfile." .. component .. " --context=dir:///cicd/workspace/src " .. (extra or "") ..
         " --destination=$REGISTRY/" .. image .. ":" .. tag .. " --cache=true --cache-repo=$REGISTRY/cinim-cache " .. REGISTRY_FLAGS
end

-- a job (its id is the first argument, 2 characters, D-67) in a volume of its own with the source of the commit in it; its steps 1 and 2 are the mirror and the clone, the steps of `fn` are 3 on
local function checked_out(id, env, fn, opts)
  opts = opts or {}
  ci.single[id]{ image = opts.image or GIT, profile = opts.profile or "build", workspace = "isolated", env = env, timeout = opts.timeout, secrets = opts.secrets, shm = opts.shm, body = function(j)
    j:run(step.cache_restore['1']{ keys = {"git-" .. env.SHA} })
    j:run(step.sh['2']{ cmd = CLONE })
    fn(j)
  end }
end

-- Is the image in the registry? (the images of the libraries and of the tests are made once)
local function in_registry(name, hash)
  return 'wget -q -O /dev/null --header "Accept: application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json" ' ..
         'http://$REGISTRY/v2/' .. name .. '/manifests/$' .. hash .. ' && echo "' .. name .. ':$' .. hash .. ' is in the registry" || '
end

-- The tests, in a Pod: the integration tests start `rqlited` themselves (tools/test/run.sh), the unit tests need nothing. The nimble packages of the image are in the home of root, which is what
-- the build profile gives a step (root of a user namespace of its own); the cache of the compiler is in the volume of the job, where the organisation's cache puts it.
local TESTS = [[
set -eu
cd src
# What fsyncs is slow on the disks of a node (76 ms on the root file system, 1.4 to 160 ms on the volume of the job, measured: the databases of the tests took 43 s to answer once), so
# the databases of the tests are in /dev/shm, which the job asked to be in memory (`shm`; tools/test/run.sh uses it when it has the room); the compiler's cache and the other
# temporary files are on the volume of the job.
export XDG_CACHE_HOME=/cicd/workspace/nimcache TMPDIR=/cicd/workspace/tmp; mkdir -p "$XDG_CACHE_HOME" "$TMPDIR"
tools/proto/nim_flatten.sh build/nimproto
tools/zmq/gen_curve_keys.sh                 # the secret halves of the test keys are not in the repository
for v in $(env | grep -o '^CICD_[A-Z_]*'); do unset "$v"; done         # this is a step of a run, and the tests are about shims that make their own
rc=0
# the compilers and the tests are niced: on a busy node the databases of the tests starve otherwise (a query waited 15 s)
CINIM_TEST_NICE=10 CINIM_RQLITE_BIN="$(command -v rqlited)" tools/test/run.sh -j "${TEST_JOBS:-2}" || rc=$?
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
# the repositories of the subcharts are named by URL in Chart.yaml and must be known to helm before it fetches from them
for u in $(grep -h '^[[:space:]]*repository:' deploy/charts/cinim-shard/Chart.yaml | awk '{print $2}' | sort -u); do helm repo add "r$(printf %s "$u" | cksum | cut -d' ' -f1)" "$u" >/dev/null; done
helm dependency build deploy/charts/cinim-shard >/dev/null
cp -r deploy/charts/cinim-shard/charts ../charts-cache
]=]

-- The core's own restart ends the Pod that this step runs next to, and the step's result is delivered to the new core when it is up (the shim keeps trying).
local ROLLOUT = [[
set -eu
printf '%s\n' "$DEPLOY_CA" > "$CICD_RUN_DIR/ca.crt"
export KUBECONFIG="$CICD_RUN_DIR/kubeconfig"
kubectl config set-cluster c --server=https://kubernetes.default.svc --certificate-authority="$CICD_RUN_DIR/ca.crt" --embed-certs=true >/dev/null
kubectl config set-credentials d --token="$DEPLOY_TOKEN" >/dev/null
kubectl config set-context x --cluster=c --user=d --namespace="$NAMESPACE" >/dev/null
kubectl config use-context x >/dev/null
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
helm upgrade "$STORAGE_RELEASE" deploy/charts/cinim-storage -n "$NAMESPACE" --reset-then-reuse-values --set image.tag="$IMAGE_TAG" --atomic --wait --timeout 10m || back
helm upgrade "$RELEASE" deploy/charts/cinim-shard -n "$NAMESPACE" --reset-then-reuse-values --set image.tag="$IMAGE_TAG" --atomic --wait --timeout 10m || back
# what runs now: the core and the module are at the tag, and ready
for d in cinim-core cinim-storage; do
  img=$(kubectl get deploy "$d" -o jsonpath='{.spec.template.spec.containers[0].image}')
  ready=$(kubectl get deploy "$d" -o jsonpath='{.status.readyReplicas}')
  case "$img" in *":$IMAGE_TAG") ;; *) echo "$d runs $img, not $IMAGE_TAG" >&2; back;; esac
  [ "${ready:-0}" -ge 1 ] || { echo "$d has no ready replica" >&2; back; }
done
echo "rolled out $IMAGE_TAG: shard revision $(revision "$RELEASE"), storage revision $(revision "$STORAGE_RELEASE")"
]]

return ci.pipeline({
  name = "cinim-self-build",
  params = {
    REGISTRY = ci.string{required = true, max_length = 200},                          -- host:port, as the build Pods reach the registry (plain HTTP)
    PULL_REGISTRY = ci.string{default = "", max_length = 200},                        -- the name the nodes pull the images from; empty: the same as REGISTRY
    TAG = ci.string{default = "", max_length = 100, pattern = "[%w%._%-]*"},          -- the tag of the images; empty: <date>-<commit>
    REPO = ci.string{default = "https://github.com/zystem/CiNim.git", max_length = 300},   -- when the run did not come from a repository (run.source)
    REF = ci.string{default = "main", max_length = 100, pattern = "[%w%._%-/]+"},     -- a branch, a tag or a SHA; the same
    NAMESPACE = ci.string{default = "cinim-001", max_length = 63},                    -- the namespace of the shard that is rolled out
    RELEASE = ci.string{default = "cinim-001", max_length = 53},                      -- the Helm release of the shard
    STORAGE_RELEASE = ci.string{default = "cinim-storage", max_length = 53},          -- the Helm release of the storage module
    BUILD = ci.bool{default = true},
    TEST = ci.bool{default = true},
    TEST_JOBS = ci.number{default = 2, min = 1, max = 16, integer = true},            -- workers of tools/test/run.sh in the Pod (a compile takes a gigabyte or two)
    BUILD_JOBS = ci.number{default = 2, min = 1, max = 4, integer = true},            -- images built at a time (each is a Kaniko Pod with its own volume; a small cluster cannot take four and a test run)
    DEPLOY = ci.bool{default = false},
  },
  main = function(run)
    local p = run.params
    local pull = (p.PULL_REGISTRY ~= "") and p.PULL_REGISTRY or p.REGISTRY
    -- where the commit is: the repository and the commit that the conductor read this script from, or the parameters
    local repo = (run.source.repository ~= "") and run.source.repository or p.REPO
    local ref = (run.source.commit ~= "") and run.source.commit or p.REF
    local tag = p.TAG
    local info
    -- 1. the mirror (a cache of the organisation: the first run fetches everything, the next ones what is new) and what the commit is
    ci.single['p']{ image = GIT, profile = "build", workspace = "isolated", env = {REPO = repo, REF = ref}, body = function(j)
      j:run(step.cache_restore['1']{ keys = {"git-none", "git-"} })            -- no key is exactly "git-none": the latest "git-<commit>" is the one restored
      info = j:run(step.sh['2']{ cmd = PREP }).outputs
      if not (info.SHA and info.TAG and info.DEPS and info.TESTDEPS and info.HELMDEPS) then error("no commit found for " .. ref) end
      j:run(step.cache_save['3']{ key = "git-" .. info.SHA, paths = {"mirror.git"} })
    end }
    tag = info.TAG
    local env = { SHA = info.SHA, IMAGE_TAG = info.TAG, DEPS = info.DEPS, TESTDEPS = info.TESTDEPS, TEST_JOBS = tostring(p.TEST_JOBS) }
    if p.BUILD or p.TEST then
      -- 2. the libraries, and the tests' image, once for as long as what they are made of stays the same
      if p.BUILD then
        checked_out('d', env, function(j)
          j:run(step.sh['3']{ cmd = in_registry("cinim-deps", "DEPS") .. kaniko("deps", "cinim-deps", "$DEPS"), image = KANIKO })
        end)
      end
      if p.TEST then
        checked_out('t', env, function(j)
          j:run(step.sh['3']{ cmd = in_registry("cinim-test", "TESTDEPS") .. kaniko("test", "cinim-test", "$TESTDEPS"), image = KANIKO })
        end)
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
              j:run(step.sh['3']{ cmd = kaniko(comp.target, comp.image, "$IMAGE_TAG", "--build-arg DEPS_IMAGE=$REGISTRY/cinim-deps:$DEPS"), image = KANIKO })
            end)
          end)
        end
      end
      if p.TEST then
        branches.tests = function()
          local key = "nim-" .. info.TESTDEPS .. "-"
          checked_out('u', env, function(j)
            j:run(step.cache_restore['3']{ keys = {key} })                -- the C the tests were compiled to by an earlier run: the next run compiles what changed
            local ok, err = pcall(function() j:run(step.sh['4']{ cmd = TESTS }) end)
            j:run(step.cache_save['5']{ key = key .. info.SHA, paths = {"nimcache"} })          -- also after a failed run: the compiling is what took the time, and it was done
            if not ok then error(err, 0) end
          end, {image = pull .. "/cinim-test:" .. info.TESTDEPS, timeout = "120m", shm = "1Gi"})      -- the databases of the tests are in memory: the disks of a node fsync in 1 ms or in 160
        end
      end
      ci.parallel(branches, {fail_fast = true})
    end
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
      end, {image = KUBECTL, profile = "deploy", secrets = {"DEPLOY_TOKEN", "DEPLOY_CA"}})
    end
    return tag
  end,
})
