## The master key of the emulator of the key service, kept in a Kubernetes Secret (tools/kekd-emu `--key-secret NAME`). The emulator used to make a new key at every
## start; the Pod of an emulator that restarted then had a key that was not the one that had sealed the secrets of a shard, and every secret in its database was lost. Now the
## first start makes the key and stores it in the Secret, and every later start reads it. Plain on purpose: the emulator is for development, never for a key that matters.
## The Secret is read and made with the Pod's ServiceAccount (get and create on secrets in its own namespace); a Secret that was made is not deleted with the Deployment.
import std/[json, base64, strutils]
import ../core/kubeapi

type KeyFromSecret* = object
  key*: seq[byte]
  made*: bool          ## this call made the Secret (a first start)
  error*: string       ## set: there is no key

func toHex(b: seq[byte]): string =
  for x in b: result.add toLowerAscii(x.toHex(2))

func fromHex(text: string): seq[byte] =
  ## 64 hexadecimal digits; empty if it is anything else
  if text.len != 64: return
  for i in 0 ..< 32:
    try: result.add byte(parseHexInt(text[2 * i .. 2 * i + 1]))
    except ValueError: return @[]

proc keyFromSecret*(k: KubeApi; namespace, name: string; makeKey: proc (): seq[byte]): KeyFromSecret =
  ## reads the key of the Secret `name`, or makes it. Two emulators that start at once both end with the key of the one that created the Secret.
  if not k.available:
    return KeyFromSecret(error: "there is no Kubernetes API to reach (outside a cluster, or a build without TLS): use --key-file")
  for attempt in 1 .. 3:
    let got = k.getObject("Secret", namespace, name)
    if got.error.len > 0: return KeyFromSecret(error: "reading the Secret " & name & ": " & got.error)
    if got.found:
      var text = ""
      try: text = decode(got.obj{"data", "key"}.getStr).strip
      except ValueError: discard
      let key = fromHex(text)
      if key.len != 32: return KeyFromSecret(error: "the Secret " & name & " must hold the key `key` as 64 hexadecimal digits")
      return KeyFromSecret(key: key, made: false)
    let fresh = makeKey()
    if fresh.len != 32: return KeyFromSecret(error: "no key could be made")
    let made = k.create("Secret", namespace, %*{"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
      "metadata": {"name": name, "labels": {"app": "kekd-emu"}}, "stringData": {"key": toHex(fresh)}})
    case made.outcome
    of oCreated: return KeyFromSecret(key: fresh, made: true)
    of oExists: discard                                # another emulator made it a moment ago: read it
    else: return KeyFromSecret(error: "making the Secret " & name & ": " & made.detail)
  KeyFromSecret(error: "the Secret " & name & " could not be read after it was made")
