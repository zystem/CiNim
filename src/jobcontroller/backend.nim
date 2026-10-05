## The seam between the job-controller's logic and Kubernetes (D-29). Everything the controller needs from the cluster is
## here, as plain Nim types and a handful of procedures - no Protobuf, no C client. The real implementation (k8s.nim) talks to
## the API server; the tests use a fake, so the decisions (verdicts, timeouts, adoption after a restart, orphan sweeps,
## retention) are tested without a cluster. Could later become a separate process if the C client has to be isolated.
import std/json

type
  PodRequest* = object
    ## What the platform wants a step Pod to be; the adapter turns it into a Pod spec (volumes, security context, ...).
    name*, image*, runId*: string
    cmd*: seq[string]            ## the container's command: the shim, its flags, `--` and the step's command
    logging*: bool               ## the shim streams logs: it needs the spool volume and the CURVE keys
    spoolBytes*: int
    build*: bool                 ## a step of the build profile: the adapter makes a build Pod of it (podsec.nim, D-42)

  PodSummary* = object
    name*, phase*: string
    createdAt*: int64            ## unix seconds

  Backend* = object
    createPod*: proc (r: PodRequest): bool
      ## true = the Pod exists afterwards (created, or it already did: create is idempotent, RUN-002)
    readPod*: proc (name: string): JsonNode
      ## the Pod as the API returned it; a `{"kind":"Status","code":404}` object for "no such Pod"; nil if the read itself failed
    readLogTail*: proc (name: string): string
      ## the last lines of the Pod's log; "" on any failure
    deletePod*: proc (name: string; graceSeconds: int): bool
      ## true = gone afterwards (deleted, or it was not there)
    execInPod*: proc (name, container, command: string): tuple[ok: bool, output: string]
      ## run a command in a running Pod and return its stdout (the command is split on spaces, no quoting); ok = it ran.
      ## The WebSocket exec of the C client is lossy for bulk data, so callers ask for small pieces and verify checksums.
    listPods*: proc (): tuple[ok: bool, pods: seq[PodSummary]]
      ## every Pod in the step namespace; ok = false when the list could not be read (then conclude nothing)
