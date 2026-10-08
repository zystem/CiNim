-- CiNim builds itself (D-42, D-47): three steps that share the run's volume (/cicd/workspace, STO-001). The first clones the source into the workspace, the
-- other two are Kaniko build Pods that build the two images of tools/image/Dockerfile.kaniko from that directory and push them to the registry; the second
-- build reads the layers of the first from the cache in the registry. The clone is a build step too, because only build Pods may reach the internet
-- (a rule for ordinary steps is not built, Q-18). Submit it through the API:
--   POST /api/v1/runs  {"project_id": "cinim", "organization": "<slug>", "script": "<this file>", "params": {"REGISTRY": "<host:port the Pods push to>", "TAG": "dev-1"}}
-- The organisation needs the build profile (build.enabled) and a build.egress rule for the registry; GitHub is reached over the public internet rule
-- (port 443). A step that exits non-zero fails the job and so the run (6.7). Parameters are plain environment variables of every step (VAR-002).
local KANIKO = "ghcr.io/osscontainertools/kaniko:v1.28.5-debug@sha256:d6d74217dc077acfd3094992e917c357080a2d3fdd1042a49e34e29a7e57c572"
local GIT = "alpine/git:v2.47.2"

local function build(target, image)
  ci.job({image = KANIKO, profile = "build"}, function(j)
    j:sh("/kaniko/executor --dockerfile=/cicd/workspace/src/tools/image/Dockerfile.kaniko --context=dir:///cicd/workspace/src --target=" .. target ..
         " --destination=$REGISTRY/" .. image .. ":$TAG --cache=true --cache-repo=$REGISTRY/cinim-cache" ..
         " --insecure --insecure-pull --skip-tls-verify --skip-tls-verify-pull")
  end)
end

return ci.pipeline({
  name = "cinim-self-build",
  params = {
    REGISTRY = ci.string{required = true, max_length = 200},                          -- host:port, as the build Pods reach the registry (plain HTTP)
    TAG = ci.string{default = "self", max_length = 100, pattern = "[%w%._%-]+"},      -- the tag of both images
    REPO = ci.string{default = "https://github.com/zystem/CiNim.git", max_length = 300},
    REF = ci.string{default = "main", max_length = 100, pattern = "[%w%._%-/]+"},     -- a branch or a tag
  },
  main = function(run)
    ci.job({image = GIT, profile = "build"}, function(j)
      j:sh('git clone --depth 1 --branch "$REF" "$REPO" src && rm -rf src/.git && git --version && ls src | head -20')
    end)
    build("core", "cinim")
    build("controller", "cinim-controller")
    return "built cinim and cinim-controller"
  end,
})
