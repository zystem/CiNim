## SHD-001, SHD-007: the slug rules, shared by the UI check and the core.
import std/[unittest, strutils]
import ../../src/core/orgrules

suite "SHD-001 slug rules":
  test "an ordinary slug is accepted":
    check checkSlug("acme", "cinim", "001") == ""
    check checkSlug("team-42", "cinim", "001") == ""
  test "only lower-case letters, digits and inner dashes":
    check checkSlug("Acme", "cinim", "001").len > 0
    check checkSlug("a_b", "cinim", "001").len > 0
    check checkSlug("-acme", "cinim", "001").len > 0
    check checkSlug("acme-", "cinim", "001").len > 0
    check checkSlug("", "cinim", "001").len > 0
  test "a slug may end in -build: builds run in the organisation's own namespace (D-42)":
    check checkSlug("acme-build", "cinim", "001") == ""
  test "digits only is refused: such names belong to shards":
    check "digits only" in checkSlug("001", "cinim", "001")
    check checkSlug("1a", "cinim", "001") == ""
  test "the reserved slugs are refused":
    for s in ["list", "api", "logs", "x"]: check "reserved" in checkSlug(s, "cinim", "001")
  test "SHD-007: the namespace name <prefix>-<shard>-<slug> must fit 63 characters":
    check namespaceName("cinim", "001", "acme") == "cinim-001-acme"
    check maxSlugLen("cinim", "001") == 63 - 5 - 3 - 2     # 53
    check checkSlug(repeat('a', 53), "cinim", "001") == ""
    let bad = checkSlug(repeat('a', 54), "cinim", "001")
    check "1 characters over" in bad and "at most 53" in bad
  test "the UI shows how many characters are left, negative when over":
    check charsLeft("cinim", "001", "acme") == 63 - len("cinim-001-acme")
    check charsLeft("cinim", "001", repeat('a', 60)) < 0
  test "a longer prefix or shard name shortens the room for the slug":
    check maxSlugLen("platform-ci", "0001") < maxSlugLen("cinim", "001")
  test "shard names are digits, prefixes are DNS-label-like":
    check validShardName("001") and validShardName("42")
    check not validShardName("") and not validShardName("a1") and not validShardName("1-2")
    check validPrefix("cinim") and validPrefix("ci-prod")
    check not validPrefix("") and not validPrefix("-ci") and not validPrefix("CI")
