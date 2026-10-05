## Rules for the slug of an organisation (SHD-001, SHD-007). Pure, so the UI check and the core's check are the same function and are
## unit-tested (tests/unit/torgrules.nim). The namespace of an organisation is `<prefix>-<shard>-<slug>` and must fit the 63 characters
## Kubernetes allows for a namespace name. The builds of an organisation run in a namespace of their own, `<prefix>-<shard>-<slug>-build`
## (the build profile), so the room for that suffix is always kept free and no slug may end with it (it would be another organisation's
## build namespace).
import std/strutils

const
  reservedSlugs* = ["list", "api", "logs", "x"]   ## paths under <basePath> that belong to the platform; digits-only names belong to shards
  maxNamespaceLen* = 63
  buildSuffix* = "-build"                          ## the namespace of the build profile is the organisation's namespace plus this

func namespaceName*(prefix, shard, slug: string): string = prefix & "-" & shard & "-" & slug

func buildNamespaceName*(prefix, shard, slug: string): string = namespaceName(prefix, shard, slug) & buildSuffix

func validShardName*(s: string): bool =
  ## the name of a shard is made of digits only (SHD-001)
  if s.len == 0 or s.len > 16: return false
  for c in s:
    if c notin {'0'..'9'}: return false
  true

func validPrefix*(s: string): bool =
  if s.len == 0 or s.len > 30 or s[0] == '-' or s[^1] == '-': return false
  for c in s:
    if c notin {'a'..'z', '0'..'9', '-'}: return false
  true

func maxSlugLen*(prefix, shard: string): int =
  ## the longest slug whose namespace names still fit, the build namespace included: 63 minus the prefix, the shard name, two
  ## dashes and `-build`
  min(63, maxNamespaceLen - prefix.len - shard.len - 2 - buildSuffix.len)

func charsLeft*(prefix, shard, slug: string): int =
  ## what the UI shows while the slug is typed: how many more characters the namespace names allow (the build namespace is the longer)
  maxNamespaceLen - buildNamespaceName(prefix, shard, slug).len

func checkSlug*(slug, prefix, shard: string): string =
  ## "" when the slug is acceptable, otherwise the reason (SHD-001)
  if slug.len == 0: return "the slug is empty"
  if slug[0] == '-' or slug[^1] == '-': return "the slug may not start or end with a dash"
  for c in slug:
    if c notin {'a'..'z', '0'..'9', '-'}: return "the slug may contain only lower-case letters, digits and dashes"
  if slug.allCharsInSet({'0'..'9'}): return "the slug may not consist of digits only (such names belong to shards)"
  if slug in reservedSlugs: return "the slug is reserved: " & slug
  if slug.endsWith(buildSuffix): return "the slug may not end with " & buildSuffix & " (that is the namespace of the builds of another organisation)"
  let left = charsLeft(prefix, shard, slug)
  if left < 0:
    return "the namespace name " & buildNamespaceName(prefix, shard, slug) & " is " & $(-left) & " characters over the limit of " &
      $maxNamespaceLen & " (at most " & $maxSlugLen(prefix, shard) & " characters for the slug)"
  ""
