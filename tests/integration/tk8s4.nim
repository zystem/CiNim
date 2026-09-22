## Spike 4 (part 4): watch resumption by resourceVersion (RUN-002) and client memory with many observed Pods (NFR-012).
import std/[unittest, json, os, strutils, times]
import common/[k8sbind, memstats]
import support/k8shelp

const
  ns = "cinim-m0d"
  img = "busybox:1.36"

var added, modified, other: int          # counted by the watch callback (plain ints, one thread)

proc onEvent(ev: cstring) {.cdecl.} =
  let s = $ev
  if s.startsWith("{\"type\":\"ADDED\""): inc added
  elif s.startsWith("{\"type\":\"MODIFIED\""): inc modified
  else: inc other

proc onData(pData: ptr pointer; pLen: ptr clong) {.cdecl.} =
  kubernets_watch_handler(pData, pLen, onEvent)

proc watch(k: K8s; g: ptr genericClient_t; rv: string; seconds: int) =
  ## one bounded watch from a resourceVersion ("0" = replay the current state as ADDED events)
  added = 0; modified = 0; other = 0
  k.api.data_callback_func = onData
  let q = list_createList()
  list_addElement(q, keyValuePair_create("watch", cast[pointer]("true".cstring)))
  list_addElement(q, keyValuePair_create("resourceVersion", cast[pointer](rv.cstring)))
  list_addElement(q, keyValuePair_create("timeoutSeconds", cast[pointer](($seconds).cstring)))
  discard Generic_listNamespaced(g, ns.cstring, q)
  k.api.data_callback_func = nil

suite "spike 4d: controller-style watch and memory":
  apiClient_setupGlobalEnv()
  let k = connectK8s()
  let pods = gclient(k, "", "v1", "pods")
  discard j(Generic_createResource(gclient(k, "", "v1", "namespaces"),
    $(%*{"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": ns}}), nil))
  let rss0 = rssBytes()
  echo "  METRIC rss after connect KiB = ", rss0 div 1024

  test "200 finished Pods exist":
    for i in 0 ..< 200:
      check create(pods, ns, stepPod("m" & $i, img, "true")){"kind"}.getStr == "Pod"
    var done = 0
    for _ in 0 ..< 240:
      let l = j(Generic_listNamespaced(pods, ns.cstring, nil))
      done = 0
      for it in l["items"]:
        if it{"status", "phase"}.getStr == "Succeeded": inc done
      if done == 200: break
      sleep 1000
    check done == 200

  test "NFR-012 client RSS while listing and watching 200 observed Pods":
    let before = rssBytes()
    let raw = Generic_listNamespaced(pods, ns.cstring, nil)      # raw JSON, not parsed here: measures the C client
    let listBytes = ($raw).len
    let after = rssBytes()
    echo "  METRIC list of 200 pods: ", listBytes div 1024, " KiB of JSON, client RSS growth KiB = ", (after - before) div 1024
    watch(k, pods, "0", 6)                                        # replays 200 ADDED events
    echo "  METRIC watch replay: ADDED=", added, " RSS after KiB = ", rssBytes() div 1024
    check added == 200
    let perPod = (rssBytes() - rss0) div 200
    echo "  METRIC RSS growth per observed pod bytes = ", perPod, " -> 500 pods ~ ", (rss0 + perPod * 500) div (1024 * 1024), " MiB"

  test "RUN-002 a watch resumed from a saved resourceVersion delivers exactly the events it missed":
    let l = j(Generic_listNamespaced(pods, ns.cstring, nil))
    let rv = l{"metadata", "resourceVersion"}.getStr
    check rv.len > 0
    for i in 0 ..< 10:                           # created while no watch is connected
      check create(pods, ns, stepPod("late" & $i, img, "true")){"kind"}.getStr == "Pod"
    sleep 2000
    watch(k, pods, rv, 8)
    echo "  METRIC resumed watch: ADDED=", added, " MODIFIED=", modified
    check added == 10                            # only the missed Pods, not the 200 old ones

  test "cleanup":
    discard Generic_deleteResource(gclient(k, "", "v1", "namespaces"), ns.cstring, nil)
