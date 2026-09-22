import std/[unittest, strutils]
import common/memstats

suite "E-004 memory observability":
  test "E-004 rss is reported":
    check rssBytes() > 0

  test "E-004 metrics expose rss and occupied memory":
    let m = renderMetrics("core")
    check "cicd_process_rss_bytes{service=\"core\"}" in m
    check "cicd_nim_occupied_bytes{service=\"core\"}" in m
