-- CiNim builds itself and rolls itself out (D-42, D-47, D-48). Four steps that share the run's volume (/cicd/workspace, STO-001):
--   1. clone the source into the workspace (a build step: only build Pods reach the internet),
--   2. 3. two Kaniko build Pods that build the two images of tools/image/Dockerfile.kaniko from that directory and push them to the registry
--      (the second reads the layers of the first from the cache in the registry),
--   4. a deploy step (profile = "deploy"): an ordinary, non-root Pod that may reach the Kubernetes API server and change the image of the core and the
--      executor with a narrow token (deployer.yaml). The step is left out when DEPLOY is false, the builds when BUILD is false.
-- Submit it through the API:
--   POST /api/v1/runs  {"project_id": "cinim", "organization": "<slug>", "script": "<this file>",
--                       "params": {"REGISTRY": "<host:port the build Pods push to>", "TAG": "dev-1", "PULL_REGISTRY": "<the name the nodes pull from>"}}
-- Or by the clock, as a trigger of the organisation (docs/triggers.md): the same script and parameters, `"kind": "schedule", "schedule": "0 2 * * *"`, `"concurrency": "skip"`. Leave TAG out
-- and every run tags its images <date>-<commit> (the clone step writes IMAGE_TAG to $CICD_ENV, which the later steps of the run read), so that a night's images are not the last night's.
-- The organisation needs the build profile (build.enabled) with a build.egress rule for the registry; for the deploy step the deploy profile
-- (deploy.enabled, deploy.kubeApiServer) and the secrets DEPLOY_TOKEN and DEPLOY_CA (deployer.yaml). A step that exits non-zero fails the job and so the run (6.7).
-- Parameters are plain environment variables of every step (VAR-002); the secrets are fetched by the shim and are never in the script.
local KANIKO = "ghcr.io/osscontainertools/kaniko:v1.28.5-debug@sha256:d6d74217dc077acfd3094992e917c357080a2d3fdd1042a49e34e29a7e57c572"
local GIT = "alpine/git:v2.47.2"
local KUBECTL = "alpine/k8s:1.34.1"

local function build(target, image)
  ci.job({image = KANIKO, profile = "build"}, function(j)
    j:sh("/kaniko/executor --dockerfile=/cicd/workspace/src/tools/image/Dockerfile.kaniko --context=dir:///cicd/workspace/src --target=" .. target ..
         " --destination=$REGISTRY/" .. image .. ":${TAG:-$IMAGE_TAG} --cache=true --cache-repo=$REGISTRY/cinim-cache" ..
         " --insecure --insecure-pull --skip-tls-verify --skip-tls-verify-pull")
  end)
end

-- The core and the executor get the new tag. The executor first: the core's own restart ends the Pod that this step runs next to, and the step's result
-- is delivered to the new core when it is up (the shim keeps trying). The strategy of both Deployments is Recreate: one Pod at a time.
local ROLLOUT = [[
set -eu
printf '%s\n' "$DEPLOY_CA" > "$CICD_RUN_DIR/ca.crt"
k="kubectl --server https://kubernetes.default.svc --certificate-authority $CICD_RUN_DIR/ca.crt --token $DEPLOY_TOKEN -n $NAMESPACE"
pull="${PULL_REGISTRY:-$REGISTRY}"; tag="${TAG:-$IMAGE_TAG}"
$k patch deployment cinim-executor -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"executor\",\"image\":\"$pull/cinim:$tag\"}]}}}}"
$k patch deployment cinim-core -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"core\",\"image\":\"$pull/cinim:$tag\",\"env\":[{\"name\":\"CINIM_CONTROLLER_IMAGE\",\"value\":\"$pull/cinim-controller:$tag\"}]}]}}}}"
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
    if run.params.BUILD then
      ci.job({image = GIT, profile = "build"}, function(j)
        j:sh('git clone --depth 1 --branch "$REF" "$REPO" src && ' ..
           'echo "IMAGE_TAG=$(date -u +%Y%m%d)-$(git -C src rev-parse --short HEAD)" >> "$CICD_ENV" && rm -rf src/.git && ls src | head -20')
      end)
      build("core", "cinim")
      build("controller", "cinim-controller")
    end
    if run.params.DEPLOY then
      ci.job({image = KUBECTL, profile = "deploy", secrets = {"DEPLOY_TOKEN", "DEPLOY_CA"}}, function(j)
        j:sh(ROLLOUT)
      end)
    end
    return "done"
  end,
})
