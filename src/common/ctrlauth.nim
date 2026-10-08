## The identity of a job controller (IAM-003, SHD-007, T-46): which namespace it may serve. Nothing is stored but a generation number:
## the bootstrap token and the credential of a namespace are HMAC-SHA256 of the namespace and the generation under the core's own
## secret key (the CURVE `core` key, which never leaves the core), so the core can make the token again when a provisioning is
## retried, and a rotation is a new generation. The bootstrap token (in a Secret of the namespace) is good until the controller has
## once polled with the credential that it gave in exchange, or until it expires; the credential is what every poll carries.
## A namespace that has no row is a single-tenant setup, trusted as before.
import std/strutils
import crunchy

type
  CredentialRow* = object
    found*: bool
    generation*: int
    confirmed*: bool              ## the controller has polled with its credential: the bootstrap token is spent
    bootstrapExpiresAt*: int64

  Verdict* = enum
    vLegacy                       ## no identity is kept for this namespace
    vOk                           ## the credential is right
    vIssue                        ## the bootstrap token is right: hand out the credential
    vRefused

  Decision* = object
    verdict*: Verdict
    confirm*: bool                ## vOk for the first time: record it, the bootstrap token is spent

func toHex(a: array[32, uint8]): string =
  const digits = "0123456789abcdef"
  for b in a:
    result.add digits[int(b shr 4)]
    result.add digits[int(b and 15)]

proc derive(master, purpose, namespace: string; generation: int): string =
  toHex(hmacSha256(master, "cinim/controller/v1/" & purpose & "|" & namespace & "|" & $generation))

proc bootstrapToken*(master, namespace: string; generation: int): string = derive(master, "bootstrap", namespace, generation)
proc controllerCredential*(master, namespace: string; generation: int): string = derive(master, "credential", namespace, generation)

proc coreSecretKey*(certs: string): string =
  ## the core's own secret key (the CURVE `core` key): the master of the controller identities and the step credentials; it leaves the core nowhere
  readFile(certs & "/curve/core.key").strip

proc stepToken*(master, runId: string; seq, attempt: int): string =
  ## The credential of one step for fetching its own secrets from core (6.7): HMAC-SHA256 under the core's key of the run, step and attempt, so a Pod
  ## cannot ask for the secrets of another step or another organisation, and nothing is stored. Core also checks that the attempt is the current one
  ## and still running, so the token is worth nothing once the step is over.
  toHex(hmacSha256(master, "cinim/step/v1|" & runId & "|" & $seq & "|" & $attempt))

func constantTimeEqual*(a, b: string): bool =
  ## the length is public, the content is compared without an early exit
  if a.len != b.len: return false
  var diff = 0
  for i in 0 ..< a.len: diff = diff or (ord(a[i]) xor ord(b[i]))
  diff == 0

proc decide*(row: CredentialRow; master, namespace, credential, bootstrap: string; now: int64): Decision =
  if namespace.len == 0 or not row.found: return Decision(verdict: vLegacy)
  if credential.len > 0:
    return
      if constantTimeEqual(credential, controllerCredential(master, namespace, row.generation)):
        Decision(verdict: vOk, confirm: not row.confirmed)
      else: Decision(verdict: vRefused)
  if bootstrap.len > 0 and not row.confirmed and now < row.bootstrapExpiresAt and
     constantTimeEqual(bootstrap, bootstrapToken(master, namespace, row.generation)):
    return Decision(verdict: vIssue)
  Decision(verdict: vRefused)
