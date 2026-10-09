## The settings of the shard that the core sends to the controllers (core/ctrlconfig.nim), from the environment the Helm chart gives the core.
import std/[unittest, tables]
import ../../src/core/ctrlconfig

proc fromTable(t: Table[string, string]): ShardSettings =
  shardSettings(proc (name: string): string {.gcsafe.} = {.cast(gcsafe).}: t.getOrDefault(name))

suite "the settings of the shard in the core":
  test "nothing set: no build profile and no run volume":
    let s = fromTable(initTable[string, string]())
    check not s.buildEnabled and not s.runStorageEnabled and s.buildSeccomp == "" and s.runStorageSize == ""
  test "the values of the chart reach the settings":
    let s = fromTable({"CINIM_BUILD": "on", "CINIM_BUILD_SECCOMP": "Localhost", "CINIM_BUILD_CAPS": "CHOWN,SETUID", "CINIM_BUILD_MEMORY_LIMIT": "8Gi",
                       "CINIM_BUILD_EPHEMERAL_LIMIT": "20Gi", "CINIM_RUN_STORAGE": "on", "CINIM_RUN_STORAGE_SIZE": "2Gi", "CINIM_RUN_STORAGE_CLASS": "fast",
                       "CINIM_RUN_STORAGE_ACCESS": "ReadWriteMany"}.toTable)
    check s.buildEnabled and s.buildSeccomp == "Localhost" and s.buildCaps == "CHOWN,SETUID" and s.buildMemoryLimit == "8Gi" and s.buildEphemeralLimit == "20Gi"
    check s.runStorageEnabled and s.runStorageSize == "2Gi" and s.runStorageClass == "fast" and s.runStorageAccess == "ReadWriteMany"
  test "`off` and anything but `on` is off":
    check not fromTable({"CINIM_BUILD": "off", "CINIM_RUN_STORAGE": "true"}.toTable).buildEnabled
    check not fromTable({"CINIM_RUN_STORAGE": "yes"}.toTable).runStorageEnabled
