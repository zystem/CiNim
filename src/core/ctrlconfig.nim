## The settings of the shard that the controller of an organisation works by (ControllerConfig of controller.proto): read from the core's own settings (the Helm values `build.*`
## and `runStorage.*` reach the core as environment) and sent with every answer to a poll of a controller. They used to be the environment of the controller's Pod, and a change of one
## then meant a new Pod of every controller; now it is applied by the controller to the next step it starts.
import std/[os, strutils]
import kubeapi, orgprovision

const
  defaultSpoolBytes* = 10 * 1024 * 1024
  defaultHoldTimeout* = 600
  defaultRetentionUnread* = 14 * 86400        ## a Pod the core could not read: 14 days, with an alert (RUN-005)

type ShardSettings* = object
  buildEnabled*: bool
  buildSeccomp*, buildCaps*, buildMemoryLimit*, buildEphemeralLimit*: string     ## "" = the controller's default
  runStorageEnabled*: bool
  runStorageSize*, runStorageClass*, runStorageAccess*: string
  collectorAddr*, stepReportAddr*, artifactAddr*, logIngestAddr*: string          ## the core's addresses for the shim and for the controller; "" = none
  logSpoolBytes*: int64
  logHoldTimeout*: int
  podRetentionRead*, podRetentionUnread*: int64                                    ## seconds a finished Pod is kept

func number(text: string; default: int64): int64 =
  try: parseBiggestInt(text.strip) except ValueError: default

func coreAddress(host: string; port: int): string = "tcp://" & host & ":" & $port

proc shardSettings*(get: proc (name: string): string {.gcsafe.}; shardNamespace = ""): ShardSettings =
  ## `shardNamespace`: the namespace the core runs in. In a cluster the addresses of the core's channels are those of its Service there; an address in the environment of the
  ## core (CINIM_COLLECTOR_ADDR, ...) wins, which is how a core outside a cluster is told where the Pods reach it. With neither there are none: no log streaming.
  let host = if shardNamespace.len > 0: coreServiceName & "." & shardNamespace & ".svc" else: ""
  proc addr(envName: string; port: int): string =
    let given = get(envName)
    if given.len > 0: given elif host.len > 0: coreAddress(host, port) else: ""
  let collector = addr("CINIM_COLLECTOR_ADDR", 19743)
  ShardSettings(
    buildEnabled: get("CINIM_BUILD") == "on", buildSeccomp: get("CINIM_BUILD_SECCOMP"), buildCaps: get("CINIM_BUILD_CAPS"),
    buildMemoryLimit: get("CINIM_BUILD_MEMORY_LIMIT"), buildEphemeralLimit: get("CINIM_BUILD_EPHEMERAL_LIMIT"),
    runStorageEnabled: get("CINIM_RUN_STORAGE") == "on", runStorageSize: get("CINIM_RUN_STORAGE_SIZE"),
    runStorageClass: get("CINIM_RUN_STORAGE_CLASS"), runStorageAccess: get("CINIM_RUN_STORAGE_ACCESS"),
    collectorAddr: collector, stepReportAddr: addr("CINIM_STEPREPORT_ADDR", 19742), artifactAddr: addr("CINIM_ARTIFACTINGEST_ADDR", 19744),
    logIngestAddr: (if get("CINIM_LOGINGEST_ADDR").len > 0: get("CINIM_LOGINGEST_ADDR") else: collector),
    logSpoolBytes: number(get("CINIM_LOG_SPOOL_BYTES"), defaultSpoolBytes), logHoldTimeout: int(number(get("CINIM_LOG_HOLD_TIMEOUT"), defaultHoldTimeout)),
    podRetentionRead: number(get("CINIM_POD_RETENTION_READ"), 0), podRetentionUnread: number(get("CINIM_POD_RETENTION_UNREAD"), defaultRetentionUnread))

proc shardSettingsFromEnv*(): ShardSettings =
  shardSettings(proc (name: string): string {.gcsafe.} = getEnv(name), ownNamespace())
