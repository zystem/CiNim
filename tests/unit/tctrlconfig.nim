## The settings of the shard that the core sends to the controllers (core/ctrlconfig.nim), from the environment the Helm chart gives the core.
import std/[unittest, tables]
import ../../src/core/ctrlconfig

proc fromTable(t: Table[string, string]; shardNamespace = ""): ShardSettings =
  shardSettings(proc (name: string): string {.gcsafe.} = {.cast(gcsafe).}: t.getOrDefault(name), shardNamespace)

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

suite "the addresses and the policy that the core sends to a controller":
  test "in a cluster the addresses are those of the core's Service in its namespace, the policy has its defaults":
    let s = fromTable(initTable[string, string](), "cinim-001")
    check s.collectorAddr == "tcp://cinim-core.cinim-001.svc:19743" and s.stepReportAddr == "tcp://cinim-core.cinim-001.svc:19742"
    check s.artifactAddr == "tcp://cinim-core.cinim-001.svc:19744" and s.logIngestAddr == s.collectorAddr
    check s.logSpoolBytes == 10 * 1024 * 1024 and s.logHoldTimeout == 600 and s.podRetentionRead == 0 and s.podRetentionUnread == 14 * 86400
  test "outside a cluster there are no addresses (no log streaming) unless the core is told them":
    let none = fromTable(initTable[string, string]())
    check none.collectorAddr == "" and none.stepReportAddr == "" and none.artifactAddr == "" and none.logIngestAddr == ""
    let told = fromTable({"CINIM_COLLECTOR_ADDR": "tcp://host:1", "CINIM_STEPREPORT_ADDR": "tcp://host:2", "CINIM_LOGINGEST_ADDR": "tcp://local:3"}.toTable)
    check told.collectorAddr == "tcp://host:1" and told.stepReportAddr == "tcp://host:2" and told.logIngestAddr == "tcp://local:3" and told.artifactAddr == ""
  test "an address in the environment wins over the Service's, and the controller's own LogIngest follows the collector's unless set":
    let s = fromTable({"CINIM_COLLECTOR_ADDR": "tcp://elsewhere:9"}.toTable, "cinim-001")
    check s.collectorAddr == "tcp://elsewhere:9" and s.logIngestAddr == "tcp://elsewhere:9" and s.stepReportAddr == "tcp://cinim-core.cinim-001.svc:19742"
  test "the policy of the core's environment, and a number that is not one is the default":
    let s = fromTable({"CINIM_LOG_SPOOL_BYTES": "2097152", "CINIM_LOG_HOLD_TIMEOUT": "45", "CINIM_POD_RETENTION_READ": "300", "CINIM_POD_RETENTION_UNREAD": "3600"}.toTable)
    check s.logSpoolBytes == 2097152 and s.logHoldTimeout == 45 and s.podRetentionRead == 300 and s.podRetentionUnread == 3600
    let bad = fromTable({"CINIM_LOG_HOLD_TIMEOUT": "soon", "CINIM_POD_RETENTION_UNREAD": ""}.toTable)
    check bad.logHoldTimeout == 600 and bad.podRetentionUnread == 14 * 86400
