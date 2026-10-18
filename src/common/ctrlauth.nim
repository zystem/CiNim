## The identity of a job controller (IAM-003, SHD-007, T-46): which namespace it may serve. Nothing is stored but a generation number:
## the bootstrap token and the credential of a namespace are HMAC-SHA256 of the namespace and the generation under the core's own
## secret key (the CURVE `core` key, which never leaves the core), so the core can make the token again when a provisioning is
## retried, and a rotation is a new generation. The bootstrap token (in a Secret of the namespace) is good until the controller has
## once polled with the credential that it gave in exchange, or until it expires; the credential is what every poll carries.
## A namespace that has no row is **not enrolled** and is refused: whoever holds the transport's `client` key could otherwise pose as the controller of a namespace the core has
## never provisioned and be handed its steps (and, through them, the secrets they ask for). Development and tests that run a controller without an identity say so (`unenrolled`).
import std/strutils
import crunchy

type
  CredentialRow* = object
    found*: bool
    generation*: int
    confirmed*: bool              ## the controller has polled with its credential: the bootstrap token is spent
    bootstrapExpiresAt*: int64

  Verdict* = enum
    vUnenrolled                   ## no identity is kept for this namespace, and the core was told to serve such controllers anyway (development)
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

proc conductorCredential*(master, namespace, conductorId: string): string =
  ## What a conductor (docs/conductors.md) proves itself with: of one namespace and one conductor, under the core's key; nothing is stored. The core
  ## makes it for the controller of the namespace, which hands it to the conductor's Pod in a Secret. The lengths are in the text, so that the
  ## boundary between the namespace and the id cannot be moved.
  toHex(hmacSha256(master, "cinim/conductor/v1|" & $namespace.len & "|" & namespace & "|" & conductorId))

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

proc decide*(row: CredentialRow; master, namespace, credential, bootstrap: string; now: int64; unenrolled = false): Decision =
  ## `unenrolled`: a controller of a namespace with no identity (or none named) is served instead of refused; false in a cluster
  if namespace.len == 0 or not row.found:
    return Decision(verdict: (if unenrolled: vUnenrolled else: vRefused))
  if credential.len > 0:
    return
      if constantTimeEqual(credential, controllerCredential(master, namespace, row.generation)):
        Decision(verdict: vOk, confirm: not row.confirmed)
      else: Decision(verdict: vRefused)
  if bootstrap.len > 0 and not row.confirmed and now < row.bootstrapExpiresAt and
     constantTimeEqual(bootstrap, bootstrapToken(master, namespace, row.generation)):
    return Decision(verdict: vIssue)
  Decision(verdict: vRefused)

type Refusal* = object
  code*, detail*: string

const credentialMismatch* = "credential_mismatch"   ## the only refusal that is about the controller's credential: the controller has to give it up and enrol again

proc refusal*(row: CredentialRow; master, namespace, credential, bootstrap: string; now: int64): Refusal =
  ## Why `decide` refused, for the controller and for the log of the core. The code says what the controller may conclude: only `credential_mismatch` means that the credential it holds is
  ## not good (a credential is a function of the master key, the namespace and the generation, so it does not become good again by waiting); every other refusal is about something
  ## else (the namespace has no identity yet, the poll names none, the bootstrap token is wrong, used or expired) and leaves the credential the controller has alone.
  if namespace.len == 0: return Refusal(code: "no_namespace", detail: "the poll names no namespace")
  if not row.found: return Refusal(code: "no_identity", detail: "the namespace has no identity (no row)")
  if credential.len > 0: return Refusal(code: credentialMismatch, detail: "the credential does not match generation " & $row.generation & " of the namespace")
  if bootstrap.len == 0: return Refusal(code: "no_credential", detail: "the controller sent no credential and no bootstrap token")
  if row.confirmed: return Refusal(code: "bootstrap_used", detail: "the bootstrap token was used already (the controller is enrolled) and the controller sent no credential")
  if now >= row.bootstrapExpiresAt: return Refusal(code: "bootstrap_expired", detail: "the bootstrap token has expired")
  Refusal(code: "bootstrap_rejected", detail: "the bootstrap token is not the one of generation " & $row.generation)
