-- CiNim builds itself and rolls itself out (D-42, D-47, D-48), the images in parallel, each build in a volume of its own (STO-002, `workspace = "isolated"`) and so on any node:
--   1. `prep`: fetch the repository into a bare mirror kept as a cache of the organisation (`git-<commit>`, docs/cache.md; the next run fetches only what is new), find the commit
--      of REF, the tag of the images and the hash of what the libraries image is made of,
--   2. `deps`: the image of the libraries (libsodium, libzmq, the Kubernetes C client, the nimble packages; tools/image/Dockerfile.deps) as `cinim-deps:<hash>`, made once and found in the registry afterwards,
--   3. the images of the components side by side (`ci.matrix`, `fail_fast`: the first build that fails stops the others): each build restores the mirror of its commit, clones from it
--      into its own volume and runs Kaniko on the Dockerfile of its component with DEPS_IMAGE (tools/image/Dockerfile.<component>) so that none of them makes the libraries,
--   4. a deploy step (profile = "deploy"): an ordinary, non-root Pod that may reach the Kubernetes API server and change the image of the core with a narrow token (deployer.yaml).
--      The step is left out when DEPLOY is false, the builds when BUILD is false.
-- Submit it through the API:
--   POST /api/v1/runs  {"organization": "<slug>", "script": "<this file>",
--                       "params": {"REGISTRY": "<host:port the build Pods push to>", "TAG": "dev-1", "PULL_REGISTRY": "<the name the nodes pull from>"}}
-- Or by the clock, as a trigger of the organisation (docs/triggers.md): the same script and parameters, `"kind": "schedule", "schedule": "0 2 * * *"`, `"concurrency": "skip"`. Leave TAG out
-- and every run tags its images <date>-<commit>, so that a night's images are not the last night's.
-- The organisation needs the build profile (build.enabled) with a build.egress rule for the registry, and a store for caches (the storage module); for the deploy step the deploy
-- profile (deploy.enabled, deploy.kubeApiServer) and the secrets DEPLOY_TOKEN and DEPLOY_CA (deployer.yaml). A step that exits non-zero fails the job and so the run (6.7).
-- Parameters are plain environment variables of every step (VAR-002); the secrets are fetched by the shim and are never in the script.
local KANIKO = "ghcr.io/osscontainertools/kaniko:v1.28.5-debug@sha256:d6d74217dc077acfd3094992e917c357080a2d3fdd1042a49e34e29a7e57c572"
local GIT = "alpine/git:v2.47.2"
local KUBECTL = "alpine/k8s:1.34.1"

-- the component (tools/image/Dockerfile.<component>) and the image it is pushed as
local COMPONENTS = { { target = "core", image = "cinim" }, { target = "controller", image = "cinim-controller" },
                     { target = "conductor", image = "cinim-conductor" }, { target = "storage", image = "cinim-storage" } }

-- the mirror, the commit and the hashes, returned to the script as outputs: SHA, TAG and DEPS (the hash of the stage of the libraries, cinim.nimble and the script of the Kubernetes client)
local PREP = [[
set -eu
[ -f mirror.git/HEAD ] || git init -q --bare mirror.git
git -C mirror.git fetch -q "$REPO" "+refs/heads/$REF:refs/heads/$REF" || git -C mirror.git fetch -q "$REPO" "+refs/tags/$REF:refs/tags/$REF"
sha=$(git -C mirror.git rev-parse "$REF^{commit}")
deps=$({ git -C mirror.git show "$sha:cinim.nimble"; git -C mirror.git show "$sha:tools/k8s/build_client.sh"; git -C mirror.git show "$sha:tools/image/Dockerfile.deps"; } | sha256sum | cut -c1-16)
{ echo "SHA=$sha"; echo "TAG=${TAG:-$(date -u +%Y%m%d)-$(echo "$sha" | cut -c1-7)}"; echo "DEPS=$deps"; } >> "$CICD_OUTPUT"
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

-- a job in a volume of its own with the source of the commit in it
local function checked_out(env, fn)
  ci.job({image = GIT, profile = "build", workspace = "isolated", env = env}, function(j)
    j.cache.restore({"git-" .. env.SHA})
    j:sh(CLONE)
    fn(j)
  end)
end

-- The core gets the new tag, and with it the images the core hands out: the controllers' and the conductors'. The core's own restart ends the Pod that this step runs next to,
-- and the step's result is delivered to the new core when it is up (the shim keeps trying). A conductor of the old image is drained when it is idle and made again with the new one.
local ROLLOUT = [[
set -eu
printf '%s\n' "$DEPLOY_CA" > "$CICD_RUN_DIR/ca.crt"
k="kubectl --server https://kubernetes.default.svc --certificate-authority $CICD_RUN_DIR/ca.crt --token $DEPLOY_TOKEN -n $NAMESPACE"
pull="${PULL_REGISTRY:-$REGISTRY}"; tag="${TAG:-$IMAGE_TAG}"
$k patch deployment cinim-core -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"core\",\"image\":\"$pull/cinim:$tag\",\"env\":[{\"name\":\"CINIM_CONTROLLER_IMAGE\",\"value\":\"$pull/cinim-controller:$tag\"},{\"name\":\"CINIM_CONDUCTOR_IMAGE\",\"value\":\"$pull/cinim-conductor:$tag\"}]}]}}}}"
echo "rolled out $pull/cinim:$tag"
]]

return ci.pipeline({
  name = "cinim-self-build",
  params = {
    REGISTRY = ci.string{required = true, max_length = 200},                          -- host:port, as the build Pods reach the registry (plain HTTP)
    PULL_REGISTRY = ci.string{default = "", max_length = 200},                        -- the name the nodes pull the images from; empty: the same as REGISTRY
    TAG = ci.string{default = "", max_length = 100, pattern = "[%w%._%-]*"},          -- the tag of both images; empty: <date>-<commit>
    REPO = ci.string{default = "https://github.com/zystem/CiNim.git", max_length = 300},
    REF = ci.string{default = "main", max_length = 100, pattern = "[%w%._%-/]+"},     -- a branch or a tag
    NAMESPACE = ci.string{default = "cinim-001", max_length = 63},                    -- the namespace of the shard that is rolled out
    BUILD = ci.bool{default = true},
    DEPLOY = ci.bool{default = false},
  },
  main = function(run)
    local tag = run.params.TAG
    if run.params.BUILD then
      -- 1. the mirror (a cache of the organisation: the first run fetches everything, the next ones what is new) and what the commit is
      local info
      ci.job({image = GIT, profile = "build", workspace = "isolated"}, function(j)
        j.cache.restore({"git-none", "git-"})            -- no key is exactly "git-none": the latest "git-<commit>" is the one restored
        info = j:sh(PREP).outputs
        if not (info.SHA and info.TAG and info.DEPS) then error("no commit found for " .. run.params.REF) end
        j.cache.save("git-" .. info.SHA, {"mirror.git"})
      end)
      tag = info.TAG
      local env = { SHA = info.SHA, IMAGE_TAG = info.TAG, DEPS = info.DEPS }
      -- 2. the libraries, once for as long as what they are made of stays the same
      checked_out(env, function(j)
        j:sh('wget -q -O /dev/null --header "Accept: application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json" ' ..
             'http://$REGISTRY/v2/cinim-deps/manifests/$DEPS && echo "cinim-deps:$DEPS is in the registry" || ' .. kaniko("deps", "cinim-deps", "$DEPS"), {image = KANIKO})
      end)
      -- 3. the components side by side
      local names, by = {}, {}
      for _, c in ipairs(COMPONENTS) do names[#names + 1] = c.target; by[c.target] = c end
      ci.parallel(ci.matrix{axes = {component = names}, fail_fast = true}, function(c)
        local comp = by[c.component]
        checked_out(env, function(j)
          j:sh(kaniko(comp.target, comp.image, "$IMAGE_TAG", "--build-arg DEPS_IMAGE=$REGISTRY/cinim-deps:$DEPS"), {image = KANIKO})
        end)
      end)
    end
    if run.params.DEPLOY then
      ci.job({image = KUBECTL, profile = "deploy", secrets = {"DEPLOY_TOKEN", "DEPLOY_CA"}, env = {IMAGE_TAG = tag}}, function(j)
        j:sh(ROLLOUT)
      end)
    end
    return tag
  end,
})
