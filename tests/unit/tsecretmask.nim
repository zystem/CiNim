## Secret masking: raw value, base64 at every alignment, URL-encoding, JSON escaping, runtime values (docs/secrets-masking.md).
import std/[unittest, strutils, base64, json, sequtils]
import zippy
import shim/[secretmask, logspool]

proc masked(secrets: seq[string]; text: string; variants = true): string =
  var m = newMasker(variants = variants)
  m.add secrets
  m.mask(text)

suite "the value itself":
  test "masked wherever it appears; short values are left alone":
    check masked(@["hunter2-secret"], "token=hunter2-secret end") == "token=*** end"
    check masked(@["abc"], "abc stays abc") == "abc stays abc"
  test "the longest value wins, a shorter one inside it does not leave a stump":
    check masked(@["secret", "secret-long-value"], "x secret-long-value y") == "x *** y"

suite "base64: every alignment, standard and URL-safe alphabet":
  test "a value embedded in a bigger base64 string at any of the three alignments is masked":
    for secret in ["s3cr3t-Passw0rd!", "Zm9vYmFy-token", "p@ss/w+rd=value", "longer-secret-value-0123456789"]:
      for prefix in ["", "a", "ab", "abc", "abcd", "Authorization: Basic user:"]:
        for suffix in ["", "x", "xy", "xyz", "\n", "@host"]:
          for urlsafe in [false, true]:
            let enc = encode(prefix & secret & suffix, safe = urlsafe)
            let m = masked(@[secret], "header " & enc & " tail")
            check secret.len > 0
            if m.contains(enc.strip(leading = false, chars = {'='})[min(enc.len, 6) .. ^3]):
              fail()          # a substantial piece of the encoded value survived: not masked
            check "***" in m
  test "plain base64 of just the value is masked":
    let s = "s3cr3t-Passw0rd!"
    check "***" in masked(@[s], "x " & encode(s) & " y")
    check s notin masked(@[s], "x " & encode(s) & " y")
  test "short values get no base64 form (a 4-8 character fragment would match ordinary text)":
    check b64Fragments("abcd").len == 0
    check b64Fragments("s3cr3t-Passw0rd!").len > 0
    check masked(@["abcd"], encode("zzabcdzz")) == encode("zzabcdzz")

suite "URL-encoding and JSON":
  test "percent-encoding in both cases, and form-encoding of spaces":
    let s = "pa ss/w@rd&x=1"
    check masked(@[s], "url?p=pa%20ss%2Fw%40rd%26x%3D1&z") == "url?p=***&z"
    check masked(@[s], "url?p=pa%20ss%2fw%40rd%26x%3d1&z") == "url?p=***&z"
    check masked(@[s], "form pa+ss%2Fw%40rd%26x%3D1 end") == "form *** end"
  test "JSON-escaped quotes, backslashes and newlines":
    let s = "q\"uote\\back-secret"
    check masked(@[s], """{"k":"q\"uote\\back-secret"}""") == """{"k":"***"}"""
  test "variants can be switched off: only the literal value is masked":
    let s = "pa ss/w@rd&x=1"
    check masked(@[s], "pa%20ss%2Fw%40rd%26x%3D1", variants = false) == "pa%20ss%2Fw%40rd%26x%3D1"
    check masked(@[s], "v: " & s, variants = false) == "v: ***"

suite "multi-line values and bounds":
  test "a multi-line value is masked line by line":
    let pem = "-----BEGIN KEY-----\nAAAAbbbbCCCCdddd\nEEEEffffGGGGhhhh\n-----END KEY-----"
    let m = masked(@[pem], "out: AAAAbbbbCCCCdddd and EEEEffffGGGGhhhh")
    check "AAAAbbbb" notin m and "EEEEffff" notin m
  test "the number of masks is bounded":
    var m = newMasker()
    m.add (0 ..< 1000).mapIt("value-number-" & $it)
    check m.count <= 256

suite "the Builder masks the records, including values registered at runtime":
  test "a value added later protects only the lines cut after it":
    var b = newBuilder("ci-x", "s1_r", 1_000_000, @["hunter2-secret"])
    var blocks = b.feed("before hunter2-secret line\n", 1)
    b.addSecrets(["late-value-123"])
    blocks.add b.feed("late-value-123 and base64 " & encode("late-value-123") & "\n", 2)
    blocks.add b.flush(3, final = true)
    var text = ""
    for blk in blocks: text.add uncompress(blk.data)
    check "hunter2-secret" notin text and "late-value-123" notin text and encode("late-value-123") notin text
    check text.count("***") == 3
