## IAM-003, T-46: the identity of a job controller, decided from a row of the credential table and what the poll carries.
import std/[unittest, strutils]
import ../../src/common/ctrlauth

const master = "core-secret-key"
let t0 = 1_000_000'i64

proc row(gen = 1, confirmed = false, expires = t0 + 3600): CredentialRow =
  CredentialRow(found: true, generation: gen, confirmed: confirmed, bootstrapExpiresAt: expires)

suite "IAM-003 controller identity":
  test "T-46 a namespace without an identity is refused, and so is a poll that names no namespace; nothing is trusted by default":
    check decide(CredentialRow(), master, "ns", "", "", t0).verdict == vRefused
    check decide(CredentialRow(), master, "ns", controllerCredential(master, "ns", 1), "", t0).verdict == vRefused      # a credential made for a row that is not there
    check decide(CredentialRow(), master, "ns", "", bootstrapToken(master, "ns", 1), t0).verdict == vRefused
    check decide(row(), master, "", "", "", t0).verdict == vRefused
    check decide(row(), master, "", controllerCredential(master, "", 1), "", t0).verdict == vRefused
  test "development: with the switch on, a controller without an identity is served, and one that has an identity is still held to it":
    check decide(CredentialRow(), master, "ns", "", "", t0, unenrolled = true).verdict == vUnenrolled
    check decide(row(), master, "", "", "", t0, unenrolled = true).verdict == vUnenrolled
    check decide(row(), master, "ns", "", "", t0, unenrolled = true).verdict == vRefused       # an enrolled namespace is never opened by the switch
    check decide(row(), master, "ns", controllerCredential(master, "other", 1), "", t0, unenrolled = true).verdict == vRefused
  test "the token and the credential are made again from the same inputs, and differ by namespace, generation and purpose":
    check bootstrapToken(master, "a", 1) == bootstrapToken(master, "a", 1)
    check bootstrapToken(master, "a", 1) != bootstrapToken(master, "b", 1)
    check bootstrapToken(master, "a", 1) != bootstrapToken(master, "a", 2)
    check bootstrapToken(master, "a", 1) != controllerCredential(master, "a", 1)
    check bootstrapToken("other-key", "a", 1) != bootstrapToken(master, "a", 1)
    check bootstrapToken(master, "a", 1).len == 64
  test "the right credential is accepted, and the first time it is recorded":
    let d = decide(row(), master, "ns", controllerCredential(master, "ns", 1), "", t0)
    check d.verdict == vOk and d.confirm
    check not decide(row(confirmed = true), master, "ns", controllerCredential(master, "ns", 1), "", t0).confirm
  test "the credential of another namespace is refused":
    check decide(row(), master, "ns", controllerCredential(master, "other", 1), "", t0).verdict == vRefused
  test "a poll with no proof is refused":
    check decide(row(), master, "ns", "", "", t0).verdict == vRefused
  test "the bootstrap token is exchanged for the credential while it is fresh and unspent":
    check decide(row(), master, "ns", "", bootstrapToken(master, "ns", 1), t0).verdict == vIssue
  test "a bootstrap token of another namespace, a wrong one, an expired one and a spent one are refused":
    check decide(row(), master, "ns", "", bootstrapToken(master, "other", 1), t0).verdict == vRefused
    check decide(row(), master, "ns", "", "nope", t0).verdict == vRefused
    check decide(row(expires = t0 - 1), master, "ns", "", bootstrapToken(master, "ns", 1), t0).verdict == vRefused
    check decide(row(confirmed = true), master, "ns", "", bootstrapToken(master, "ns", 1), t0).verdict == vRefused
  test "the bootstrap token is not a credential, and the credential is not a bootstrap token":
    check decide(row(), master, "ns", bootstrapToken(master, "ns", 1), "", t0).verdict == vRefused
    check decide(row(), master, "ns", "", controllerCredential(master, "ns", 1), t0).verdict == vRefused
  test "a rotation makes the old credential and the old token useless and the new ones work":
    let old = controllerCredential(master, "ns", 1)
    check decide(row(gen = 2), master, "ns", old, "", t0).verdict == vRefused
    check decide(row(gen = 2), master, "ns", "", bootstrapToken(master, "ns", 1), t0).verdict == vRefused
    check decide(row(gen = 2), master, "ns", "", bootstrapToken(master, "ns", 2), t0).verdict == vIssue
    check decide(row(gen = 2), master, "ns", controllerCredential(master, "ns", 2), "", t0).verdict == vOk
  test "the comparison looks at every byte":
    check constantTimeEqual("abc", "abc") and not constantTimeEqual("abc", "abd") and not constantTimeEqual("abc", "ab")

suite "IAM-003 the credential of a conductor":
  test "a conductor credential is of one namespace and one conductor, and is not a controller's":
    check conductorCredential(master, "ns", "c-1") == conductorCredential(master, "ns", "c-1")
    check conductorCredential(master, "ns", "c-1") != conductorCredential(master, "ns", "c-2")
    check conductorCredential(master, "ns", "c-1") != conductorCredential(master, "other", "c-1")
    check conductorCredential(master, "ns", "c-1") != controllerCredential(master, "ns", 1)
    check conductorCredential("another master", "ns", "c-1") != conductorCredential(master, "ns", "c-1")
  test "the boundary between the namespace and the id cannot be shifted":
    check conductorCredential(master, "a", "b|c") != conductorCredential(master, "a|b", "c")

suite "IAM-003 why a controller was refused":
  test "the reason is a code the controller can act on, and a text for the log of the core":
    check refusal(row(), master, "", "c", "", t0).code == "no_namespace"
    check refusal(CredentialRow(), master, "ns", "c", "", t0).code == "no_identity"
    check refusal(row(confirmed = true), master, "ns", "", "", t0).code == "no_credential"
    let wrong = refusal(row(gen = 2, confirmed = true), master, "ns", controllerCredential(master, "ns", 1), "", t0)
    check wrong.code == credentialMismatch and "generation 2" in wrong.detail
    check refusal(row(), master, "ns", "", "wrong", t0).code == "bootstrap_rejected"
    check refusal(row(expires = t0 - 1), master, "ns", "", bootstrapToken(master, "ns", 1), t0).code == "bootstrap_expired"
    check refusal(row(confirmed = true), master, "ns", "", bootstrapToken(master, "ns", 1), t0).code == "bootstrap_used"
  test "every refusal that decide makes has a reason, and a poll decide accepts has none worth acting on":
    # the same inputs as decide's own tests: whatever decide refuses, refusal names
    for (r, cred, boot) in [(CredentialRow(), "", ""), (row(), "", ""), (row(confirmed = true), "", ""), (row(), controllerCredential(master, "other", 1), ""),
                            (row(), "", "wrong"), (row(confirmed = true), "", bootstrapToken(master, "ns", 1)), (row(expires = t0 - 1), "", bootstrapToken(master, "ns", 1))]:
      check decide(r, master, "ns", cred, boot, t0).verdict == vRefused
      check refusal(r, master, "ns", cred, boot, t0).code.len > 0
  test "only the refusal that says the credential is wrong is about the credential":
    for code in ["no_namespace", "no_identity", "no_credential", "bootstrap_used", "bootstrap_expired", "bootstrap_rejected", "", "something_new"]:
      check code != credentialMismatch
    check credentialMismatch == "credential_mismatch"
