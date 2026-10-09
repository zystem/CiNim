## The settings of the shard that the controller of an organisation works by (ControllerConfig of controller.proto): read from the core's own settings (the Helm values `build.*`
## and `runStorage.*` reach the core as environment) and sent with every answer to a poll of a controller. They used to be the environment of the controller's Pod, and a change of one
## then meant a new Pod of every controller; now it is applied by the controller to the next step it starts.
import std/os

type ShardSettings* = object
  buildEnabled*: bool
  buildSeccomp*, buildCaps*, buildMemoryLimit*, buildEphemeralLimit*: string     ## "" = the controller's default
  runStorageEnabled*: bool
  runStorageSize*, runStorageClass*, runStorageAccess*: string

proc shardSettings*(get: proc (name: string): string {.gcsafe.}): ShardSettings =
  ShardSettings(
    buildEnabled: get("CINIM_BUILD") == "on", buildSeccomp: get("CINIM_BUILD_SECCOMP"), buildCaps: get("CINIM_BUILD_CAPS"),
    buildMemoryLimit: get("CINIM_BUILD_MEMORY_LIMIT"), buildEphemeralLimit: get("CINIM_BUILD_EPHEMERAL_LIMIT"),
    runStorageEnabled: get("CINIM_RUN_STORAGE") == "on", runStorageSize: get("CINIM_RUN_STORAGE_SIZE"),
    runStorageClass: get("CINIM_RUN_STORAGE_CLASS"), runStorageAccess: get("CINIM_RUN_STORAGE_ACCESS"))

proc shardSettingsFromEnv*(): ShardSettings =
  shardSettings(proc (name: string): string {.gcsafe.} = getEnv(name))
