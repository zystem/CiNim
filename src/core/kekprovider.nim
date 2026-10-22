## The seam for the master key of the step secrets (core/secretvault.nim): something that wraps and unwraps a data key. The key may be in a file, derived from the
## core's CURVE key, or on a token that another machine holds (core/transitclient.nim); the vault asks only for these two operations and for the name of the key.
##
## An answer says why it failed: `retry` is true when asking again later may work (the token's machine is down, the token is locked, the network is slow),
## false when the key refused for good (a different key, a damaged text). The vault passes that on, so that a shim whose step starts while the token's machine
## restarts waits, and one whose secret was sealed under another key does not.

import std/[strutils, base64]

type
  WrapResult* = tuple[ok, retry: bool, error, wrapped: string]
  UnwrapResult* = tuple[ok, retry: bool, error: string, plain: seq[byte]]

  KekProvider* = object
    id*: string                                  ## which key this is; kept with what it wraps
    wrap*: proc (plain: seq[byte]; aad: string): WrapResult {.gcsafe.}
    unwrap*: proc (wrapped: string; aad: string): UnwrapResult {.gcsafe.}
    rewrap*: proc (wrapped: string; aad: string): WrapResult {.gcsafe.}   ## the same data key sealed again by the service, in its current format and key version, without the core seeing it; nil when the key cannot do that (a file, the core's own key)

func unavailable*(why: string): UnwrapResult = (false, true, why, @[])
func refused*(why: string): UnwrapResult = (false, false, why, @[])

func sealFormat*(wrapped: string): string =
  ## The format a key service sealed a text in: `vault:v<N>:<base64 of "ecies2.…">` is "ecies2" (hsmgate; Vault's own Transit texts have no such word and give ""). Used to tell what `rewrap` still has to move.
  let parts = wrapped.split(':')
  if parts.len != 3 or parts[0] != "vault": return ""
  let head = try: decode(parts[2][0 ..< min(parts[2].len, 16)].strip(chars = {'='})) except ValueError: ""
  let dot = head.find('.')
  if dot > 0 and head[0 ..< dot].startsWith("ecies"): head[0 ..< dot] else: ""
