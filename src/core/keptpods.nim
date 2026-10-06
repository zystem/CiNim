## The Pods that the job controllers keep because core could not read from them what it needs (the result is unknown, or the log did not reach
## the log store): each controller reports them in its poll (`PollRequest.kept`), core keeps the last picture per namespace and shows an alert for
## every Pod and a metric for the count. The Pod is kept 14 days (`CINIM_POD_RETENTION_UNREAD`) and is then removed by its controller, which
## also ends the alert. State is a JSON string per namespace under a lock, as the router client's is.
import std/[json, locks, tables]

type
  KeptItem* = object
    pod*, runId*, reason*: string
    seq*, attempt*: int
    reportedAt*, keepUntil*: int64

var
  lock: Lock
  pictures: Table[string, string]      ## namespace -> JSON of the last picture
initLock(lock)

proc recordKept*(namespace: string; at: int64; total: int; items: seq[KeptItem]) =
  ## the whole picture of one namespace, replacing the last one
  var arr = newJArray()
  for i in items:
    arr.add %*{"pod": i.pod, "run_id": i.runId, "seq": i.seq, "attempt": i.attempt, "reason": i.reason, "reported_at": i.reportedAt,
               "keep_until": i.keepUntil}
  let p = $(%*{"at": at, "total": total, "pods": arr})
  {.cast(gcsafe).}:
    withLock lock:
      if total == 0: pictures.del namespace else: pictures[namespace] = p

proc forgetKept*(namespace: string) =
  {.cast(gcsafe).}:
    withLock lock: pictures.del namespace

proc keptAlerts*(): JsonNode =
  ## one alert per kept Pod: what it is, why it could not be read, and until when it is kept
  result = newJArray()
  var snapshot: seq[(string, string)]
  {.cast(gcsafe).}:
    withLock lock:
      for ns, p in pictures: snapshot.add (ns, p)
  for (ns, p) in snapshot:
    let j = parseJson(p)
    for it in j["pods"]:
      let reason = it["reason"].getStr
      result.add %*{"code": "pod_unread", "namespace": ns, "pod": it["pod"], "run_id": it["run_id"], "seq": it["seq"], "attempt": it["attempt"],
                    "reason": reason, "reported_at": it["reported_at"], "keep_until": it["keep_until"],
                    "detail": "the Pod of step " & $it["seq"].getInt & " of run " & it["run_id"].getStr & " could not be fully read (" & reason &
                              "); it is kept until it is removed at keep_until, so that it can be looked at"}

proc keptCounts*(): seq[(string, int)] =
  {.cast(gcsafe).}:
    withLock lock:
      for ns, p in pictures: result.add (ns, parseJson(p)["total"].getInt)
