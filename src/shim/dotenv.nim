## Parser for the dotenv subset of STO-003 (files CICD_ENV and CICD_OUTPUT), with the
## deny-list of STO-004 and the limits and control-character rules of SEC-011.
## The file is data: it is never given to a shell.

import std/[strutils]

type
  EnvVar* = tuple[name, value: string]

  EnvError* = object of CatchableError
    code*: string   ## "env_rejected" or "secret_in_output"
    line*: int

const
  maxValueBytes* = 8 * 1024
  maxKeys* = 256
  maxTotalBytes* = 64 * 1024
  deniedNames = ["PATH", "IFS", "BASH_ENV", "ENV", "SHELL", "HOME", "NODE_OPTIONS", "NODE_PATH", "PYTHONPATH",
                 "PYTHONHOME", "PYTHONSTARTUP", "RUBYOPT", "RUBYLIB", "PERL5OPT", "PERL5LIB", "JAVA_TOOL_OPTIONS",
                 "_JAVA_OPTIONS", "JDK_JAVA_OPTIONS", "GCONV_PATH", "HOSTALIASES", "LOCPATH", "NLSPATH",
                 "PS4", "PROMPT_COMMAND", "CDPATH", "GLOBIGNORE", "SHELLOPTS", "BASHOPTS"]
  deniedPrefixes = ["LD_", "CICD_", "BASH_FUNC_", "DYLD_", "GLIBC_"]

proc reject(code, msg: string; line: int): ref EnvError =
  (ref EnvError)(msg: msg & (if line > 0: " (line " & $line & ")" else: ""), code: code, line: line)

proc validName(name: string): bool =
  if name.len == 0 or name.len > 256: return false
  if name[0] notin {'A'..'Z', '_'}: return false
  for c in name:
    if c notin {'A'..'Z', '0'..'9', '_'}: return false
  true

proc denied(name: string): bool =
  if name in deniedNames: return true
  for p in deniedPrefixes:
    if name.startsWith(p): return true

proc checkValue(value: string; line: int) =
  for c in value:
    # only TAB and (from escapes or multi-line blocks) LF may appear; every other control byte is refused
    if (c < ' ' and c != '\t' and c != '\n') or c == '\x7f':
      raise reject("env_rejected", "control character 0x" & toHex(ord(c), 2) & " in value", line)
  if value.len > maxValueBytes:
    raise reject("env_rejected", "value longer than " & $maxValueBytes & " bytes", line)

proc unquote(raw: string; line: int): string =
  ## raw starts with '"' and must end with the matching unescaped '"'.
  var i = 1
  while true:
    if i >= raw.len: raise reject("env_rejected", "unterminated quoted value", line)
    let c = raw[i]
    if c == '"':
      if i != raw.high: raise reject("env_rejected", "text after closing quote", line)
      return
    if c == '\\':
      inc i
      if i >= raw.len: raise reject("env_rejected", "unterminated escape", line)
      case raw[i]
      of 'n': result.add '\n'
      of 't': result.add '\t'
      of 'r': raise reject("env_rejected", "escape \\r is not allowed", line)
      of '\\': result.add '\\'
      of '"': result.add '"'
      else: raise reject("env_rejected", "unknown escape \\" & $raw[i], line)
    else: result.add c
    inc i

proc putVar(res: var seq[EnvVar]; total: var int; secrets: seq[string]; name, value: string; line: int) =
  checkValue(value, line)
  for s in secrets:
    if s.len > 0 and s in value:
      raise reject("secret_in_output", "value of " & name & " contains a known secret", line)
  var found = false
  for e in res.mitems:
    if e.name == name:
      total -= e.value.len
      e.value = value
      found = true
  if not found:
    if res.len >= maxKeys: raise reject("env_rejected", "more than " & $maxKeys & " keys", line)
    total += name.len
    res.add (name, value)
  total += value.len
  if total > maxTotalBytes: raise reject("env_rejected", "more than " & $maxTotalBytes & " bytes in total", line)

proc parseEnvFile*(text: string; secrets: seq[string] = @[]): seq[EnvVar] =
  ## Later duplicates replace earlier ones. Raises EnvError (env_rejected or secret_in_output).
  let lines = text.split('\n')
  var i = 0
  var total = 0
  while i < lines.len:
    let ln = lines[i]
    inc i
    if ln.len == 0: continue
    let lineNo = i
    let heredoc = ln.find("<<")
    let eq = ln.find('=')
    if heredoc > 0 and (eq < 0 or heredoc < eq):
      let name = ln[0 ..< heredoc]
      let delim = ln[heredoc + 2 .. ^1]
      if not validName(name): raise reject("env_rejected", "invalid name", lineNo)
      if delim.len == 0 or delim.len > 64 or not delim.allCharsInSet({'A'..'Z', 'a'..'z', '0'..'9', '_'}):
        raise reject("env_rejected", "invalid heredoc delimiter", lineNo)
      if denied(name): raise reject("env_rejected", name & " is on the deny-list", lineNo)
      var body: seq[string]
      var closed = false
      while i < lines.len:
        let b = lines[i]
        inc i
        if b == delim: closed = true; break
        body.add b
      if not closed: raise reject("env_rejected", "heredoc " & delim & " is not closed", lineNo)
      putVar(result, total, secrets, name, body.join("\n"), lineNo)
    elif eq > 0:
      let name = ln[0 ..< eq]
      let raw = ln[eq + 1 .. ^1]
      if not validName(name): raise reject("env_rejected", "invalid name", lineNo)
      if denied(name): raise reject("env_rejected", name & " is on the deny-list", lineNo)
      putVar(result, total, secrets, name, (if raw.len > 0 and raw[0] == '"': unquote(raw, lineNo) else: raw), lineNo)
    else:
      raise reject("env_rejected", "expected NAME=VALUE or NAME<<DELIM", lineNo)
