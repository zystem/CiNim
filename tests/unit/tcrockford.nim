## D-67, D-68: the ids of jobs (2 characters), of steps (4) and the names of pipelines `NN.lua` (2) are Crockford base32 in lowercase of a fixed width: a shorter one is padded with
## leading zeros, upper case is read as lower case, and `i l o u`, other characters, nothing and too much are refused. `a` and `0a` are one id; the strings of a fixed width sort in
## the order of the numbers.
import std/[unittest, strutils, algorithm, sequtils]
import common/crockford

suite "D-67 the ids in Crockford base32 of a fixed width":
  test "D-67 the alphabet is Crockford's in lowercase":
    check crockfordDigits == "0123456789abcdefghjkmnpqrstvwxyz"
  test "D-67 a shorter id is padded with leading zeros to its width":
    check normalizeId("a", jobIdWidth) == "0a"
    check normalizeId("0", jobIdWidth) == "00"
    check normalizeId("ab", stepIdWidth) == "00ab"
    check normalizeId("z", stepIdWidth) == "000z"
    check normalizeId("abc", stepIdWidth) == "0abc"
    check normalizeId("abcd", stepIdWidth) == "abcd"
    check normalizeId("00", jobIdWidth) == "00"
  test "D-67 upper case is read as lower case, so a and A and 0a and 0A are one id":
    check normalizeId("A", jobIdWidth) == "0a"
    check normalizeId("0A", jobIdWidth) == "0a"
    check normalizeId("AB", stepIdWidth) == "00ab"
    check normalizeId("a", jobIdWidth) == normalizeId("0A", jobIdWidth)
  test "D-67 i l o u are refused, in both cases, with a message that names the character":
    for bad in ["i", "l", "o", "u", "I", "L", "O", "U", "ai", "0l", "ou"]:
      let r = checkId(bad, jobIdWidth)
      check not r.ok
      check bad.toLowerAscii.filterIt(it in "ilou").len > 0
      check ("'" & $bad.toLowerAscii.filterIt(it in "ilou")[0] & "'") in r.message
  test "D-67 other characters, nothing, and too much are refused":
    check not checkId("", jobIdWidth).ok
    check not checkId("a-", jobIdWidth).ok
    check not checkId("a b", stepIdWidth).ok
    check not checkId("a_", jobIdWidth).ok
    check not checkId("é", jobIdWidth).ok
    check not checkId("abc", jobIdWidth).ok          # three characters for a job
    check not checkId("abcde", stepIdWidth).ok       # five for a step
    check "at most 2" in checkId("abc", jobIdWidth).message
    check "at most 4" in checkId("abcde", stepIdWidth).message
    check checkId("ab", jobIdWidth).ok and checkId("a", jobIdWidth).ok and checkId("abcd", stepIdWidth).ok
  test "D-67 the strings of a fixed width sort in the order of the numbers":
    var all: seq[string]
    for i in 0 ..< 1024: all.add idOfNumber(i, jobIdWidth)
    check all == all.sorted
    check all[0] == "00" and all[1] == "01" and all[31] == "0z" and all[32] == "10" and all[1023] == "zz"
    check numberOfId("zz") == 1023 and numberOfId("0a") == 10 and numberOfId("00ab") == 10 * 32 + 11
  test "D-67 a number that does not fit its width is refused":
    check idOfNumber(1023, 2) == "zz"
    expect ValueError: discard idOfNumber(1024, 2)
    expect ValueError: discard idOfNumber(-1, 2)
    check idOfNumber(1048575, 4) == "zzzz"
  test "D-68 the name of a pipeline file is NN.lua with NN one or two characters of the alphabet, and 0.lua is 00.lua":
    check pipelineOfFile("0.lua") == "00" and pipelineOfFile("00.lua") == "00"
    check pipelineOfFile("a.lua") == "0a" and pipelineOfFile("A.lua") == "0a" and pipelineOfFile("0a.lua") == "0a"
    check pipelineOfFile("zz.lua") == "zz"
    check pipelineOfFile("pipeline.lua") == ""        # not a name of a pipeline
    check pipelineOfFile("000.lua") == ""
    check pipelineOfFile("i.lua") == "" and pipelineOfFile("0o.lua") == ""
    check pipelineOfFile("00.txt") == "" and pipelineOfFile(".lua") == "" and pipelineOfFile("00") == ""
  test "D-68 two files of one pipeline in a repository are an error that names both":
    let r = findPipelines(@[".ci/0.lua", ".ci/00.lua", ".ci/1.lua", ".ci/readme.md", ".ci/pipeline.lua"])
    check not r.ok
    check ".ci/0.lua" in r.message and ".ci/00.lua" in r.message
    let fine = findPipelines(@[".ci/1.lua", ".ci/0a.lua", ".ci/00.lua", ".ci/other.txt"])
    check fine.ok
    check fine.pipelines == @["00", "01", "0a"]       # sorted, normalized
    check findPipelines(@[".ci/a.lua", ".ci/0A.lua"]).ok == false
