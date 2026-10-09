## The emulator of the key service keeps its key in a Kubernetes Secret (kekd/keysecret.nim): made at the first start, read at every later one.
import std/[unittest, json, base64, tables, strutils, sequtils]
import ../../src/core/kubeapi
import ../../src/kekd/keysecret

type Fake = ref object
  secrets: Table[string, JsonNode]     ## namespace/name -> the Secret as the API server keeps it (stringData turned into base64 data)
  calls: seq[string]
  failCreate: int                      ## answer a create with this HTTP code when not 0
  racer: bool                          ## another emulator makes the Secret between our read and our create

proc fakeApi(f: Fake): KubeApi =
  KubeApi(transport: proc (meth, path, body: string): tuple[code: int, body: string] =
    f.calls.add meth & " " & path
    let parts = path.split('/')
    let ns = parts[parts.find("namespaces") + 1]
    if meth == "GET":
      let key = ns & "/" & parts[^1]
      if key in f.secrets: return (200, $f.secrets[key])
      return (404, """{"kind":"Status","code":404}""")
    if meth == "POST":
      if f.failCreate != 0: return (f.failCreate, """{"kind":"Status","message":"forbidden"}""")
      let obj = parseJson(body)
      let name = obj["metadata"]["name"].getStr
      var stored = %*{"metadata": {"name": name}, "data": {"key": encode(obj["stringData"]["key"].getStr)}}
      if f.racer and ns & "/" & name notin f.secrets:
        f.racer = false
        f.secrets[ns & "/" & name] = %*{"data": {"key": encode("ab".repeat(32))}}
        return (409, """{"kind":"Status","code":409}""")
      if ns & "/" & name in f.secrets: return (409, """{"kind":"Status","code":409}""")
      f.secrets[ns & "/" & name] = stored
      return (201, $stored)
    (500, ""))

proc counting(): proc (): seq[byte] =
  var n = 0
  result = proc (): seq[byte] =
    inc n
    for i in 0 ..< 32: result.add byte(n * 16 + i)

suite "the key of the emulator in a Secret":
  test "the first start makes the Secret, a later start reads the same key":
    let f = Fake()
    let first = keyFromSecret(fakeApi(f), "ns", "kekd-emu-key", counting())
    check first.error == "" and first.made and first.key.len == 32
    let again = keyFromSecret(fakeApi(f), "ns", "kekd-emu-key", counting())
    check again.error == "" and not again.made and again.key == first.key
  test "the Secret holds the key as 64 hexadecimal digits under `key`":
    let f = Fake()
    let r = keyFromSecret(fakeApi(f), "ns", "k", counting())
    let text = decode(f.secrets["ns/k"]["data"]["key"].getStr)
    check text.len == 64 and text.toLowerAscii == text
    check text == r.key.mapIt(it.toHex(2).toLowerAscii).join("")
  test "two emulators that start at once end with the key of the one that made the Secret":
    let f = Fake(racer: true)
    let r = keyFromSecret(fakeApi(f), "ns", "k", counting())
    check r.error == "" and not r.made and r.key == newSeq[byte](32).mapIt(0xab'u8)
  test "a Secret with something else in it is an error, not a new key":
    let f = Fake()
    f.secrets["ns/k"] = %*{"data": {"key": encode("not a key")}}
    check keyFromSecret(fakeApi(f), "ns", "k", counting()).error.contains("64 hexadecimal digits")
    f.secrets["ns/j"] = %*{"data": {}}
    check keyFromSecret(fakeApi(f), "ns", "j", counting()).error.contains("64 hexadecimal digits")
  test "a refusal to make the Secret is told with the API server's words, and no key is used":
    let f = Fake(failCreate: 403)
    let r = keyFromSecret(fakeApi(f), "ns", "k", counting())
    check r.key.len == 0 and r.error.contains("forbidden")
  test "outside a cluster there is no key to use":
    check keyFromSecret(KubeApi(), "ns", "k", counting()).error.contains("--key-file")
