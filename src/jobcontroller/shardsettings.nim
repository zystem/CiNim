## The settings of the shard that the controller works by (ControllerConfig of controller.proto): the build profile (D-42, podsec.nim) and the volume of a run (STO-001, runvolume.nim).
## They come from the core with every answer to a poll and replace what the controller has; until the first answer there are none, which is the default of each: no build
## profile. A step is never started before the first answer, since the steps themselves come in answers.
import podsec, runvolume

type ShardSettings* = object
  build*: BuildSettings
  volume*: VolumeSettings

func shardSettings*(buildEnabled: bool; buildSeccomp, buildCaps, buildMemoryLimit, buildEphemeralLimit: string;
                    storageSize, storageClass, storageAccess: string): ShardSettings =
  ## an empty string is the default of that setting
  ShardSettings(
    build: buildSettings(if buildEnabled: "on" else: "off", buildCaps, buildMemoryLimit, buildSeccomp, buildEphemeralLimit),
    volume: volumeSettings(storageSize, storageClass, storageAccess))
