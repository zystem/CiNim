## D-42: the security class of a step Pod. An ordinary step stays as it was; a step of the build profile is a build Pod, which the
## admission policy of the chart (deploy/examples/build-pods/policy.yaml) lets through, and only in the two classes tested here.
import std/[unittest, json]
import ../../src/jobcontroller/podsec

let kaniko = buildSettings("on", "", "", "")
let rootless = buildSettings("on", "CHOWN,SETUID", "8Gi", "Localhost")

suite "D-42 the Pod of a step":
  test "an ordinary step is non-root with nothing added, and carries no build label":
    let s = podSecurity(kaniko, false)
    check s.podCtx["runAsNonRoot"].getBool and s.podCtx["runAsUser"].getInt == 1000
    check not s.containerCtx["allowPrivilegeEscalation"].getBool and s.containerCtx["capabilities"]["drop"][0].getStr == "ALL"
    check s.hostUsers and s.labels.len == 0
  test "a build step on a shard without the build profile is an ordinary Pod":
    check podSecurity(buildSettings("off", "", "", ""), true).labels.len == 0
    check podSecurity(buildSettings("", "", "", ""), true).podCtx["runAsNonRoot"].getBool
  test "the Kaniko class: root of a user namespace of its own, the default seccomp profile, six capabilities":
    let s = podSecurity(kaniko, true)
    check s.labels["cinim.io/profile"].getStr == "build" and not s.hostUsers
    check s.podCtx["runAsUser"].getInt == 0 and s.podCtx["seccompProfile"]["type"].getStr == "RuntimeDefault"
    check $s.containerCtx["capabilities"]["add"] == """["CHOWN","DAC_OVERRIDE","FOWNER","SETUID","SETGID","SETFCAP"]"""
    check s.containerCtx["capabilities"]["drop"][0].getStr == "ALL"
    check s.resources["limits"]["memory"].getStr == "4Gi"
  test "the rootless class: user 1000 under the Localhost profile of the cluster, still a user namespace of its own":
    let s = podSecurity(rootless, true)
    check s.labels["cinim.io/profile"].getStr == "build" and not s.hostUsers
    check s.podCtx["runAsUser"].getInt == 1000 and s.podCtx["seccompProfile"]["type"].getStr == "Localhost"
    check s.podCtx["seccompProfile"]["localhostProfile"].getStr == "profiles/cinim-userns.json"
    check s.containerCtx.len == 0 and s.resources["limits"]["memory"].getStr == "8Gi"
  test "the operator's capabilities and memory limit are used by the Kaniko class":
    let s = podSecurity(buildSettings("on", "CHOWN,SETUID", "2Gi", "RuntimeDefault"), true)
    check $s.containerCtx["capabilities"]["add"] == """["CHOWN","SETUID"]""" and s.resources["limits"]["memory"].getStr == "2Gi"
