## Process memory metrics: RSS and Nim heap occupancy (E-004).

import std/strutils

proc rssBytes*(): int =
  ## Resident set size from /proc/self/statm; 0 when unavailable.
  try:
    let f = open("/proc/self/statm")
    defer: f.close()
    let parts = f.readLine().splitWhitespace()
    if parts.len >= 2:
      result = parseInt(parts[1]) * 4096
  except CatchableError:
    result = 0

proc renderMetrics*(service: string): string =
  ## Prometheus text exposition of the two mandatory memory gauges.
  result = "# TYPE cicd_process_rss_bytes gauge\n" &
    "cicd_process_rss_bytes{service=\"" & service & "\"} " & $rssBytes() & "\n" &
    "# TYPE cicd_nim_occupied_bytes gauge\n" &
    "cicd_nim_occupied_bytes{service=\"" & service & "\"} " & $getOccupiedMem() & "\n"
