## UI templates (UI-009, ADR 0012): nimja does not escape HTML, so every {{ expression }} must go through h() (escape) or raw()
## (explicitly trusted HTML, e.g. server-rendered SVG). This test fails the build on any other expression.
import std/[unittest, os, strutils]
import ui/render

const hostile = "<script>alert(1)</script> & \"q\" 'x'"

suite "UI-009 template safety":
  test "the guard finds expressions that are not wrapped in h() or raw()":
    check unescapedExpressions("<td>{{ r.name }}</td>") == @["r.name"]
    check unescapedExpressions("<td>{{ h(r.name) }}{{ raw(svg) }}</td>").len == 0
    check unescapedExpressions("{{ h(a) }} {{ b }} {{ raw(c) }} {{ d.e }}") == @["b", "d.e"]
    check unescapedExpressions("{% for r in rows %}{{ h(r.id) }}{% endfor %}").len == 0

  test "every template under src/ui/templates passes the guard":
    var checked = 0
    for f in walkFiles("src/ui/templates/*.nimja"):
      inc checked
      check unescapedExpressions(readFile(f)) == newSeq[string]()
    check checked > 0

  test "h() neutralises markup, quotes and ampersands":
    let e = h(hostile)
    check "<" notin e and ">" notin e and "\"" notin e and "'" notin e
    check "&lt;script&gt;" in e and "&amp;" in e

  test "rendering the run list with hostile data yields no live markup from the data":
    let page = renderRunList(@[RunRow(id: 1, name: hostile, state: "ok\"><img src=x onerror=alert(1)>")])
    check "<script>" notin page and "<img" notin page and "onerror=alert" notin page.replace("onerror=alert(1)&gt;", "")
    check "&lt;script&gt;" in page
