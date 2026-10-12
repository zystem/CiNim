## PRJ-001, D-54: the names and paths of groups (core/groups.nim). Pure.
import std/[unittest, strutils]
import core/groups

suite "PRJ-001 the path of a group":
  test "a path is slugs joined by '/', extra slashes are nothing, the root is empty":
    check pathParts("team/backend") == @["team", "backend"]
    check pathParts("/team//backend/") == @["team", "backend"]
    check normalPath("/team//backend/") == "team/backend"
    check pathParts("").len == 0 and pathParts("/").len == 0 and normalPath("///") == ""
  test "a group's name: lowercase letters, digits and '-', starting with a letter, at most 40, and not 'variables'":
    for ok in ["a", "team", "team-2", "a1-b2-c3"]: check validGroupSlug(ok)
    for bad in ["", "Team", "1team", "-x", "te_am", "te am", "variables"]: check not validGroupSlug(bad)
    check validGroupSlug("a" & repeat('b', 39)) and not validGroupSlug("a" & repeat('b', 40))
  test "at most eight levels":
    check maxGroupDepth == 8
