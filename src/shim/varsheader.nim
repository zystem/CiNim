## VAR-005: the header of the first step of a run. It prints in the step's log the effective values of the plain variables and launch parameters, and a short digest of them -
## the first 12 hex digits of the SHA-256 over the sorted `NAME=value` lines, one per line - so that the question "which values did this run use" is answered by the log. Secret
## variables are not printed (their names are listed with `***`) and do not enter the digest. The core names the variables in `CICD_VARIABLES` (a comma-separated list), only
## for the first step; the values are read from the shim's own environment, so the header tells what the command is really given. The text goes through the log pipeline, so
## masking applies to it as to any line.
import std/[strutils, algorithm]
import checksums/sha2

const
  variablesEnv* = "CICD_VARIABLES"
  prefix = "cicd-shim: "

func digestOf*(lines: seq[string]): string =
  ## 12 hex digits of the SHA-256 of the lines, sorted, joined by a newline
  var sorted = lines
  sorted.sort()
  for c in secureHash(Sha_256, sorted.join("\n")): result.add toHex(ord(c), 2).toLowerAscii
  result.setLen 12

proc buildHeader*(names: string; value: proc (name: string): string; secrets: seq[string]): string =
  ## `names`: the core's list; `value`: the environment of the shim; `secrets`: the names of the step's secrets. "" if there is nothing to say.
  var plain: seq[string]
  for n in names.split(','):
    if n.len > 0 and n notin secrets: plain.add n
  plain.sort()
  var lines: seq[string]
  for n in plain: lines.add n & "=" & value(n)
  if lines.len == 0 and secrets.len == 0: return ""
  result = prefix & "variables (digest " & digestOf(lines) & ")\n"
  for l in lines: result.add prefix & "  " & l & "\n"
  if secrets.len > 0:
    var s = secrets
    s.sort()
    for n in s: result.add prefix & "  " & n & "=***\n"
