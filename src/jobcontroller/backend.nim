## The seam between the job-controller's logic and Kubernetes (D-29). Everything the controller needs from the cluster is
## here, as plain Nim types and a handful of procedures - no Protobuf, no C client. The real implementation (k8s.nim) talks to
## the API server; the tests use a fake, so the decisions (verdicts, timeouts, adoption after a restart, orphan sweeps,
## retention) are tested without a cluster. Could later become a separate process if the C client has to be isolated.
import std/[json, strutils]
import ../common/envname

type
  PodRequest* = object
    ## What the platform wants a step Pod to be; the adapter turns it into a Pod spec (volumes, security context, ...).
    name*, image*, runId*: string
    cmd*: seq[string]            ## the container's command: the shim, its flags, `--` and the step's command
    logging*: bool               ## the shim streams logs: it needs the spool volume and the CURVE keys
    spoolBytes*: int
    secrets*: seq[string]        ## the names of the step's secrets: the Pod's environment holds a placeholder for each, the shim fetches the values from core
    env*: seq[(string, string)]  ## plain environment of the step: the run's launch parameters (VAR-002); never a secret
    build*: bool                 ## a step of the build profile: the adapter makes a build Pod of it (podsec.nim, D-42)

  PodSummary* = object
    name*, phase*: string
    createdAt*: int64            ## unix seconds

  CreateKind* = enum
    ckOk          ## the Pod exists afterwards (created, or it already did: create is idempotent, RUN-002)
    ckQuota       ## the namespace's quota is used up (403 `exceeded quota`) or the API server asks to wait (429): try again later, the step is not at fault
    ckRejected    ## the API server refused the Pod for good (admission, Pod Security, an invalid spec): a retry would be refused the same way
    ckTransport   ## no answer at all: the Pod may or may not exist, the next poll finds out

  CreateOutcome* = object
    kind*: CreateKind
    reason*, message*: string    ## the API server's Status `reason` and `message`, for the investigation

  Backend* = object
    createPod*: proc (r: PodRequest): CreateOutcome
    readPod*: proc (name: string): JsonNode
      ## the Pod as the API returned it; a `{"kind":"Status","code":404}` object for "no such Pod"; nil if the read itself failed
    readEvents*: proc (name: string): seq[JsonNode]
      ## the Kubernetes events about the Pod (FailedScheduling, Evicted, Killing, ...), which the cluster forgets after about an hour; nil when not available
    readLogTail*: proc (name: string): string
      ## the last lines of the Pod's log; "" on any failure
    deletePod*: proc (name: string; graceSeconds: int): bool
      ## true = gone afterwards (deleted, or it was not there)
    execInPod*: proc (name, container, command: string): tuple[ok: bool, output: string]
      ## run a command in a running Pod and return its stdout (the command is split on spaces, no quoting); ok = it ran.
      ## The WebSocket exec of the C client is lossy for bulk data, so callers ask for small pieces and verify checksums.
    listPods*: proc (): tuple[ok: bool, pods: seq[PodSummary]]
      ## every Pod in the step namespace; ok = false when the list could not be read (then conclude nothing)

func ok*(o: CreateOutcome): bool =
  ## the Pod exists, or may (a transport failure is settled by the next poll)
  o.kind in [ckOk, ckTransport]

func classifyCreateFailure*(code: int; reason, message: string): CreateOutcome =
  ## What a refused `create pod` means for the step. A used-up quota or a request to slow down passes by itself: the step waits in the queue.
  ## Everything else (Pod Security, an admission policy, an invalid spec) would be refused again: it is a fault of the platform's setup, not of the step.
  if code == 429 or (code == 403 and "exceeded quota" in message):
    CreateOutcome(kind: ckQuota, reason: reason, message: message)
  else:
    CreateOutcome(kind: ckRejected, reason: reason, message: message)

func podEnv*(r: PodRequest): seq[(string, string)] =
  ## The container's environment: the run's launch parameters as they are, and for each secret the placeholder the shim replaces with the value it
  ## fetches from core (the Pod's specification holds no secret value). A secret of the same name as a parameter wins.
  for (n, v) in r.env:
    if n notin r.secrets: result.add (n, v)
  for n in r.secrets: result.add (n, stepSecretPlaceholder(n))
