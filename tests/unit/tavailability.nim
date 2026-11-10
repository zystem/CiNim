## D-114: the registries a group may use. The organisation has them all; each group down the tree may narrow the set and none may widen it; an empty list inherits. Pure.
import std/[unittest, strutils]
import core/projectpolicy

suite "D-114 the registries a group may use are narrowed down the tree":
  test "the organisation has them all, an empty list changes nothing":
    let root = Availability(all: true)
    check root.available("gh") and root.available("anything")
    check root.narrow(@[]).all
  test "the first list makes the set; the next narrows it and keeps only what both allow":
    let g = Availability(all: true).narrow(@["gh", "hub", "lan"])
    check not g.all and g.names == @["gh", "hub", "lan"] and g.available("hub") and not g.available("quay")
    let p = g.narrow(@["hub", "lan", "quay"])                       # quay is not allowed above: it does not come back
    check p.names == @["hub", "lan"] and not p.available("quay") and not p.available("gh")
  test "an empty list below inherits the set above, and a set can go down to nothing":
    let g = Availability(all: true).narrow(@["gh"])
    check g.narrow(@[]).names == @["gh"]
    let none = g.narrow(@["hub"])                                    # nothing in common: no registry at all
    check not none.all and none.names.len == 0 and not none.available("gh") and not none.available("hub")
  test "the refusal names the registry and the setting":
    check "gh" in registryRefused("gh") and "allowed_registries" in registryRefused("gh")
