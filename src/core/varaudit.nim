## The audit of changes of variables and secrets (VAR-006, AUD-002): off by default; the setting `audit_variables` of the organisation's profile turns it on in one of two modes.
## `full`: for a plain variable the old and the new value are written in full. `digest`: a plain value longer than 256 characters is written as a digest only (the value is in the log
## header of a step that used it, VAR-005). A secret variable is never written, in either mode: the audit has the fact of the change (who, when, the new version) and a digest.
## The digest is the first 12 hex digits of an HMAC-SHA256 under a key of the tenant (made of the core's secret key and the tenant), not a plain hash, so that a short or guessable
## secret cannot be found by trying values against the audit. The variables of the shard belong to no organisation and are always written in full (the operator makes them; they are plain).
import std/[options, strutils, json]
import crunchy
import ../common/rqlite
import audit, apiauth

const
  digestLen = 12
  digestFrom* = 256                       ## `digest` mode: a plain value this long or longer is written as its digest

func toHex(a: array[32, uint8]): string =
  const digits = "0123456789abcdef"
  for b in a:
    result.add digits[int(b shr 4)]
    result.add digits[int(b and 15)]

proc tenantKey(master, tenant: string): string =
  ## the key of a tenant for the digests of the audit (not the key of its secrets)
  toHex(hmacSha256(master, "cinim/audit-digest/v1|" & tenant))

proc valueDigest*(master, tenant, name, value: string): string =
  ## "hmac:" and 12 hex digits; the name is part of the input, so the same text in two variables gives two digests
  "hmac:" & toHex(hmacSha256(tenantKey(master, tenant), name & "\0" & value))[0 ..< digestLen]

proc variableAuditMode*(c: var RqClient; tenantId: string): string =
  ## "off", "digest" or "full" of the organisation; the shard's variables (no tenant) are "full"
  if tenantId.len == 0: return "full"
  let v = c.query(%*[["SELECT audit_variables FROM execution_profiles WHERE tenant_id = ? LIMIT 1", tenantId]])["results"][0]{"values"}
  if v != nil and v.len > 0 and v[0][0].kind == JString: v[0][0].getStr else: "off"

proc plainShown(mode, master, tenant, name, value: string): string =
  if mode == "digest" and value.len >= digestFrom: valueDigest(master, tenant, name, value) else: value

proc recordVariable*(c: var RqClient; mode, master, tenant: string; now: int64; who: Principal; level, name: string; before, after: Option[string]) =
  ## a plain variable was set (`after` is some) or deleted (`after` is none); `level` is "shard", "organization acme" or "group acme/team/backend"
  if mode == "off": return
  let action = if after.isSome: "variable.set" else: "variable.delete"
  c.record(now, actorOf(who), action, level & "/" & name, "ok", "",
           before = (if before.isSome: plainShown(mode, master, tenant, name, before.get) else: ""),
           after = (if after.isSome: plainShown(mode, master, tenant, name, after.get) else: ""))

proc recordSecret*(c: var RqClient; mode, master, tenant: string; now: int64; who: Principal; org, name: string; version: int; value: Option[string]) =
  ## a secret was set (with the new `version` and its `value`, of which only the digest is kept) or deleted (`value` is none)
  if mode == "off": return
  if value.isSome:
    c.record(now, actorOf(who), "secret.set", "organization " & org & "/" & name, "ok", "version " & $version, after = valueDigest(master, tenant, name, value.get))
  else:
    c.record(now, actorOf(who), "secret.delete", "organization " & org & "/" & name, "ok")
