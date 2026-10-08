## The seam for the master key of the step secrets (core/secretvault.nim): something that wraps and unwraps a data key. The key may be in a file, derived from the
## core's CURVE key, or on a token that another machine holds (core/kekclient.nim); the vault asks only for these two operations and for the name of the key.
##
## An answer says why it failed: `retry` is true when asking again later may work (the token's machine is down, the token is locked, the network is slow),
## false when the key refused for good (a different key, a damaged text). The vault passes that on, so that a shim whose step starts while the token's machine
## restarts waits, and one whose secret was sealed under another key does not.

type
  WrapResult* = tuple[ok, retry: bool, error, wrapped: string]
  UnwrapResult* = tuple[ok, retry: bool, error: string, plain: seq[byte]]

  KekProvider* = object
    id*: string                                  ## which key this is; kept with what it wraps
    wrap*: proc (plain: seq[byte]; aad: string): WrapResult {.gcsafe.}
    unwrap*: proc (wrapped: string; aad: string): UnwrapResult {.gcsafe.}

func unavailable*(why: string): UnwrapResult = (false, true, why, @[])
func refused*(why: string): UnwrapResult = (false, false, why, @[])
