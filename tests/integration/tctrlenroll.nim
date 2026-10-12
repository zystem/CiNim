## T-46, IAM-003: a controller whose namespace the core has no identity for is refused (against a real rqlite). Needs CINIM_RQLITE_URL; otherwise skipped.
import std/[unittest, json, os, times, strutils]
import common/[rqlite, ctrlauth]
import core/[schema, scheduler]

let url = getEnv("CINIM_RQLITE_URL")
const master = "master-key-of-the-test"

suite "T-46 controllers without an identity":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    let defaultProfile = c.seedDefaultProfile("cinim-default-ns")
    let sfx = newId()[^8 .. ^1].toLowerAscii
    let was = unenrolledControllers
    defer: unenrolledControllers = was
    proc poll(ns: string; credential = ""; bootstrap = ""): PollResponse =
      handlePoll(c, defaultProfile, master, PollRequest(session_id: "jc-" & sfx & ns, namespace: ns, credential: credential, bootstrap_token: bootstrap, free_pod_slots: 1))

    test "a namespace the core never provisioned is refused, and so is a poll that names none":
      unenrolledControllers = false
      check poll("never-" & sfx).unauthorized
      check poll("").unauthorized
      check poll("never-" & sfx, credential = controllerCredential(master, "never-" & sfx, 1)).unauthorized
    test "an enrolled namespace is served against its credential only, and the bootstrap token is exchanged once":
      unenrolledControllers = false
      let ns = "enrolled-" & sfx
      c.ensureCredentialRow(ns, getTime().toUnix() + 3600)
      check poll(ns).unauthorized
      let issued = poll(ns, bootstrap = bootstrapToken(master, ns, 1))
      check not issued.unauthorized and issued.issued_credential == controllerCredential(master, ns, 1)
      check not poll(ns, credential = controllerCredential(master, ns, 1)).unauthorized
      check poll(ns, credential = controllerCredential(master, "other", 1)).unauthorized
    test "with the switch on (development) a namespace without an identity is served, and an enrolled one is still held to its credential":
      unenrolledControllers = true
      check not poll("dev-" & sfx).unauthorized
      check not poll("").unauthorized
      let ns = "enrolled2-" & sfx
      c.ensureCredentialRow(ns, getTime().toUnix() + 3600)
      check poll(ns).unauthorized
