import std/[strutils, parseutils]
import nimja

type Row* = object
  id*: int
  name*, state*: string

proc renderPage*(): string =
  var rows: seq[Row]
  for i in 0 ..< 100: rows.add Row(id: i, name: "pipeline-" & $i, state: (if i mod 7 == 0: "failed" else: "ok"))
  compileTemplateStr("<!doctype html><html><head><meta charset=utf-8><title>Runs</title></head><body><h1>Runs</h1><table>\n{% for r in rows %}<tr><td>{{ r.id }}</td><td>{{ r.name }}</td><td class=\"{{ r.state }}\">{{ r.state }}</td></tr>\n{% endfor %}</table></body></html>\n")

proc rssKb*(): int =
  var b: int
  discard parseInt(readFile("/proc/self/statm").splitWhitespace()[1], b)
  b * 4
