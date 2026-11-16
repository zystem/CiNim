## What the API says when a handler fails with an exception that nothing expected (specification 9.1: an error is Problem Details with a `request_id`). The text of such an exception is not the
## client's: it may hold a query, a path of the inside, the address of the database. The client is told a reference (the `request_id` of the answer); the log of the core has the same reference with the request, the kind
## of the exception and its text. Until 2026-11-16 the text itself was the `detail` of the 500, also for the routes that need no login (the login, the webhooks, the OIDC callback).
import std/[strutils, sysrand]

proc failureRef*(): string =
  ## eight hexadecimal digits by which a line of the log is found; random, so that a client learns nothing from two of them
  var raw: array[4, byte]
  if not urandom(raw): return "00000000"
  for b in raw: result.add toHex(int(b), 2).toLowerAscii

proc apiFailure*(reference, meth, uri: string; e: ref Exception): tuple[detail, log: string] =
  ## `detail` for the client, `log` for the operator (one line: the text of the exception without its line ends and cut at 300 characters; the address without its query)
  let q = uri.find('?')
  let path = if q >= 0: uri[0 ..< q] else: uri
  var msg = if e.isNil: "" else: e.msg
  for i in 0 ..< msg.len:
    if msg[i] in {'\n', '\r'}: msg[i] = ' '
  if msg.len > 300: msg = msg[0 ..< 300] & "..."
  result.detail = "an internal error; the log of the core has it as " & reference
  result.log = "core: api: internal error " & reference & ": " & meth & " " & path & ": " & (if e.isNil: "nil" else: $e.name) & ": " & msg
