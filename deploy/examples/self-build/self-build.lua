-- CiNim builds itself (D-42): two build steps, each a Kaniko build Pod of the organisation, with the source taken from git (Kaniko's git
-- context) and the two images of tools/image/Dockerfile.kaniko pushed to the registry. Submit it through the API:
--   POST /api/v1/runs  {"project_id": "cinim", "organization": "<slug>", "script": "<this file, REGISTRY replaced>"}
-- The organisation needs the build profile (build.enabled) and a build.egress rule for the registry; GitHub is reached over the public internet
-- rule (port 443). A step that exits non-zero fails the job and so the run (6.7).
local KANIKO = "gcr.io/kaniko-project/executor:v1.23.2-debug"
local REG = "REGISTRY"
local function build(target, image)
  ci.job({image = KANIKO, profile = "build"}, function(j)
    j:sh("/kaniko/executor --dockerfile=tools/image/Dockerfile.kaniko --context=git://github.com/zystem/CiNim.git#refs/heads/main --target=" .. target ..
             " --destination=" .. REG .. "/" .. image .. ":self-1 --cache=true --cache-repo=" .. REG .. "/cinim-cache --insecure --insecure-pull --skip-tls-verify --skip-tls-verify-pull")
  end)
end
return ci.pipeline({name = "cinim-self-build", main = function(run)
  build("core", "cinim")
  build("controller", "cinim-controller")
  return "built cinim and cinim-controller"
end})
