## IAM-003, T-46: the identity of a job controller, decided from a row of the credential table and what the poll carries.
import std/unittest
import ../../src/common/ctrlauth

const master = "core-secret-key"
let t0 = 1_000_000'i64

proc row(gen = 1, confirmed = false, expires = t0 + 3600): CredentialRow =
  CredentialRow(found: true, generation: gen, confirmed: confirmed, bootstrapExpiresAt: expires)

suite "IAM-003 controller identity":
  test "a namespace without an identity is a single-tenant setup and is trusted":
    check decide(CredentialRow(), master, "ns", "", "", t0).verdict == vLegacy
    check decide(row(), master, "", "", "", t0).verdict == vLegacy          # a poll that names no namespace
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
