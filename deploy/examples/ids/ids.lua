-- Ids built in a loop (docs/parallel.md section 3.3). An id names a step, is 1 to 8 letters and digits starting with a letter, and is unique in the run; a repeat fails the
-- run with `duplicate_id`. `b58f` builds it from a format in which every number shows how many characters it takes: `{x}` one, `{xx}` two (digits and letters of Base58, 0 to
-- 3363 in two, so the 200 steps of a run fit). The format is checked as a whole: at most 8 characters, a letter first, one argument for each placeholder.
-- This script runs today; with `ci.parallel` the two loops become two groups of branches (docs/parallel.md section 2).
local images = { "api", "web", "worker", "cron", "docs" }

return ci.pipeline({
  name = "ids",
  main = function(run)
    ci.job({ image = "gcr.io/kaniko-project/executor:debug" }, function(j)
      for i, name in ipairs(images) do
        j:sh("build " .. name, { id = b58f("b{xx}", i) })        -- b12, b13 ... : 3 characters each
      end
    end)
    ci.job({ image = "aquasec/trivy:latest" }, function(j)
      for i, name in ipairs(images) do
        j:sh("trivy image registry.example.com/" .. name, { id = b58f("s{xx}", i) })     -- s12, s13 ...
      end
    end)
  end,
})
