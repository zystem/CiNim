## The settings of the shard in the controller (jobcontroller/shardsettings.nim): what the core sends in each answer to a poll becomes the security class of a build Pod and the volume of a run.
import std/[unittest, json, strutils]
import ../../src/jobcontroller/[shardsettings, podsec, runvolume]

suite "the settings of the shard in a controller":
  test "nothing set: no build profile, no run volume, the defaults of each":
    let s = shardSettings(false, "", "", "", "", false, "", "", "")
    check not s.build.enabled and not s.volume.enabled
    check s.volume.size == "5Gi" and not s.volume.readWriteMany
  test "a build profile with the settings of the shard: Kaniko's class by default, the rootless class on request":
    let kaniko = shardSettings(true, "", "", "", "", false, "", "", "")
    check kaniko.build.enabled and not kaniko.build.localhost and kaniko.build.memoryLimit == "4Gi"
    let rootless = shardSettings(true, "Localhost", "CHOWN,SETUID", "8Gi", "20Gi", false, "", "", "")
    check rootless.build.localhost and rootless.build.caps == @["CHOWN", "SETUID"] and rootless.build.memoryLimit == "8Gi" and rootless.build.ephemeralLimit == "20Gi"
    check podSecurity(rootless.build, true).podCtx["seccompProfile"]["type"].getStr == "Localhost"
  test "a run volume with a size, a class and an access mode":
    let s = shardSettings(false, "", "", "", "", true, "20Gi", "fast", "ReadWriteMany")
    check s.volume.enabled and s.volume.size == "20Gi" and s.volume.storageClass == "fast" and s.volume.readWriteMany
    check claimBody(s.volume, "s1_r")["spec"]["resources"]["requests"]["storage"].getStr == "20Gi"
  test "a later answer replaces the earlier: the next Pod is made by the new settings":
    var current = shardSettings(true, "", "", "", "", true, "5Gi", "", "")
    check podSecurity(current.build, true).labels.len > 0 and current.volume.size == "5Gi"
    current = shardSettings(false, "", "", "", "", true, "1Gi", "", "")
    check podSecurity(current.build, true).labels.len == 0 and current.volume.size == "1Gi"        # a build step is an ordinary Pod when the shard has no build profile
