## Server-side rendering helpers (UI-009). nimja compiles templates at build time (about 10 us for a 100-row page) but does not escape:
## write every dynamic value as {{ h(x) }} (escaped) or {{ raw(x) }} (trusted HTML). tests/unit/ttemplates.nim enforces it.

import std/[strutils, re, os]
import nimja

type RunRow* = object
  id*: int
  name*, state*: string

func h*(s: string): string =
  ## HTML-escape text and attribute values (both quote kinds)
  for c in s:
    case c
    of '&': result.add "&amp;"
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    of '"': result.add "&quot;"
    of '\'': result.add "&#39;"
    else: result.add c

func h*(n: int): string = $n
func raw*(s: string): string = s     # explicit marker: the caller vouches that s is safe HTML

proc unescapedExpressions*(tpl: string): seq[string] =
  ## the {{ ... }} expressions of a nimja template that are not a direct h(...) or raw(...) call
  for m in tpl.findAll(re"\{\{(.*?)\}\}"):
    let e = m[2 .. ^3].strip
    if not (e.startsWith("h(") or e.startsWith("raw(")) or not e.endsWith(")"): result.add e

const templateDir = currentSourcePath().parentDir

proc renderRunList*(rows: seq[RunRow]): string =
  compileTemplateFile("templates/runlist.nimja", templateDir)
