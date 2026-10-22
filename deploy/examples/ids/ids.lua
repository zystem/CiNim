-- Ids built in a loop (D-67, docs/parallel.md section 3.3). The id of a job and of a step is the index of the call, `ci.single["a"]{ ... }` and `step.sh["ab"]{ ... }`: Crockford base32
-- in lowercase (0-9 and a-z without i, l, o, u), a job's 2 characters and a step's 4, a shorter one padded with zeros in front. The id of a job is unique in the run and the id of a step
-- in its job; a repeat fails the run with `duplicate_id`. `b32f` builds an id from loop variables from a format in which every number shows how many characters it takes: `{x}` one
-- (0 to 31), `{xx}` two (0 to 1023), `{xxx}` three, `{xxxx}` four. The format is checked as a whole; nothing is padded by `b32f`.
local images = { "api", "web", "worker", "cron", "docs" }

return ci.pipeline({
  name = "ids",
  main = function(run)
    ci.single["b"] {
      name  = "build",
      image = "gcr.io/kaniko-project/executor:debug",
      body  = function(j)
        for i, name in ipairs(images) do
          j:run(step.sh[b32f("{xx}", i)] { name = "build " .. name, cmd = "build " .. name })      -- 01, 02 ... : the step ids, padded to 4 characters
        end
      end,
    }
    ci.single["s"] {
      name  = "scan",
      image = "aquasec/trivy:latest",
      body  = function(j)
        for i, name in ipairs(images) do
          j:run(step.sh[b32f("{xx}", i)] { name = "scan " .. name, cmd = "trivy image registry.example.com/" .. name })
        end
      end,
    }
  end,
})
