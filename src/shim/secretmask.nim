## Secret masking in the shim (DAT-002, SEC-011; docs/secrets-masking.md). Pure, std only.
## A secret reaches the log not only as itself: the build base64-encodes it into a header, puts it into a URL, prints it
## inside JSON. So each registered value is masked in all those forms (`variants`), and the build can register more values
## while it runs (the $CICD_MASK file, handled by the shim). Everything is masked before the text leaves the shim - the Pod
## log, the spool and core never see the plain value.
##
## Limits worth knowing (they are in the docs too): a value shorter than `minLen` is not masked (it would mangle ordinary
## output); a base64 form is only masked when its recognisable fragment is at least `minFragment` characters (so short values
## get the raw, URL and JSON forms only); a value split across two lines is masked line by line, never across the break;
## a value registered at runtime protects the lines that come after the registration.
import std/[strutils, base64, json, algorithm]

const
  defaultMinLen* = 4
  minFragment = 8             ## shorter base64 fragments could appear in ordinary text by chance
  maxMasks = 256              ## a bound on the work per line, whatever the build registers
  maskText* = "***"

type Masker* = object
  minLen: int
  variants: bool
  list: seq[string]           ## longest first, so a value inside a longer one is not masked piecemeal

func b64Fragments*(secret: string): seq[string] =
  ## The base64 text a value leaves inside a bigger base64 string depends on its alignment (it can start at the 1st, 2nd or
  ## 3rd byte of a 3-byte group): the three alignments are computed, and the characters that also depend on the neighbouring
  ## bytes (the first partial group at the front, the last partial one at the back) are cut off - what remains is
  ## identical wherever the value is embedded. Both the standard and the URL-safe alphabet.
  let whole = encode(secret)                           # the value on its own, with its final character and padding
  if whole.strip(leading = false, chars = {'='}).len >= minFragment:
    for w in [whole, whole.strip(leading = false, chars = {'='})]:
      result.add w
      result.add w.multiReplace(("+", "-"), ("/", "_"))
  for k in 0 .. 2:
    let enc = encode(repeat('\0', k) & secret).strip(leading = false, chars = {'='})
    let lead = (8 * k + 5) div 6                       # characters touched by the k prefix bytes
    let tail = if (k + secret.len) mod 3 == 0: 0 else: 1  # the last character mixes the value's bits with padding bits
    if enc.len - tail <= lead: continue
    let frag = enc[lead ..< enc.len - tail]
    if frag.len < minFragment: continue
    result.add frag
    result.add frag.multiReplace(("+", "-"), ("/", "_"))

func percentEncode(s: string; upper: bool; plusForSpace: bool): string =
  const hexU = "0123456789ABCDEF"
  const hexL = "0123456789abcdef"
  for c in s:
    if c in {'A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_', '~'}: result.add c
    elif c == ' ' and plusForSpace: result.add '+'
    else:
      let h = if upper: hexU else: hexL
      result.add '%'
      result.add h[ord(c) shr 4]
      result.add h[ord(c) and 15]

func variantsOf*(secret: string): seq[string] =
  ## Every form of `secret` worth masking besides itself.
  result.add b64Fragments(secret)
  for u in [percentEncode(secret, true, false), percentEncode(secret, false, false),
            percentEncode(secret, true, true), percentEncode(secret, false, true)]:
    if u != secret: result.add u
  let j = escapeJson(secret)
  let jj = j[1 .. ^2]                                   # without the quotes
  if jj != secret: result.add jj

func newMasker*(minLen = defaultMinLen; variants = true): Masker =
  Masker(minLen: max(minLen, 1), variants: variants)

func count*(m: Masker): int = m.list.len

func add*(m: var Masker; values: openArray[string]) =
  ## Register values (each line of a multi-line value separately - the log is masked line by line).
  var fresh: seq[string]
  for v in values:
    for line in v.splitLines:
      let l = line.strip(leading = false, chars = {'\r'})
      if l.len < m.minLen: continue
      fresh.add l
      if m.variants: fresh.add variantsOf(l)
  for f in fresh:
    if f.len >= m.minLen and f notin m.list and m.list.len < maxMasks: m.list.add f
  m.list.sort(proc (a, b: string): int = cmp(b.len, a.len))

func mask*(m: Masker; line: string): string =
  result = line
  for s in m.list:
    if result.len >= s.len and s in result: result = result.replace(s, maskText)
