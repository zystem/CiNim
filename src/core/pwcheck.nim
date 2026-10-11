## IAM-001: is a password a person chose a good one? Two checks after the length rule (rbac.nim `passwordProblem`).
##
## 1. **Local rules** (cheap, no network, always applied): too few different characters (`1111111111111111`), a short group repeated (`sexsexsexsexsex`), a run of
##    neighbours on the alphabet, the digits or the keyboard (`1234567890123456`, `qwertyuiopasdfgh`), and nothing but common words and digits (`iloveyou12345678`).
##    They catch what a dictionary of breached passwords would hold in its first lines, and cost nothing.
## 2. **Have I Been Pwned** (Pwned Passwords, the range API with k-anonymity): the SHA-1 of the password is made here and only its **first 5 hex digits** are sent
##    (`GET <base>/<5 digits>`, with `Add-Padding: true` so that the size of the answer tells nothing); the answer lists the suffixes of the hashes that begin so,
##    with how many times each was seen in breaches, and the match is made here. The password and its full hash do not leave the core. When the service does not
##    answer (no route out, a timeout, an error) the check is **skipped, not failed**: the local rules were applied, and the answer says `breach_check: local`.
##    `CINIM_PWNED_CHECK=off` skips it on purpose (an air-gapped shard); `CINIM_PWNED_URL` points to a mirror of the range API; `CINIM_PWNED_TIMEOUT_MS` (3000).
import std/[strutils, unicode, httpclient, os, tables, algorithm]
import crunchy

const
  defaultPwnedUrl* = "https://api.pwnedpasswords.com/range/"
  defaultPwnedTimeoutMs* = 3000
  minDistinct = 6                  ## fewer different characters than this is refused
  neighbourShare = 0.75            ## this share of the steps from one character to the next being a step along a sequence is refused
  leftoverLetters = 3              ## what is left of a password after its common words and digits are taken out, at most this many letters, is refused

  commonWords = [
    "password", "passw0rd", "passwd", "pass", "qwertyuiop", "qwerty", "qwertz", "azerty", "asdfghjkl", "asdfgh", "zxcvbnm", "zxcvbn", "admin", "administrator",
    "root", "user", "login", "welcome", "letmein", "iloveyou", "monkey", "dragon", "football", "baseball", "basketball", "master", "shadow", "sunshine",
    "princess", "superman", "batman", "trustno", "hello", "freedom", "whatever", "ninja", "mustang", "michael", "jordan", "harley", "ranger", "jennifer",
    "hunter", "buster", "soccer", "hockey", "killer", "george", "charlie", "andrew", "michelle", "love", "sex", "secret", "god", "jesus", "abc", "test",
    "guest", "changeme", "default", "computer", "internet", "cookie", "summer", "winter", "spring", "autumn", "flower", "pokemon", "starwars", "matrix",
    "naruto", "fuck", "shit", "ass", "porn", "money", "lovely", "angel", "tiger", "lucky", "cheese", "pepper", "ginger", "cinim", "cicd", "runner", "build",
    "deploy", "token", "access", "master", "super", "pwd", "letmein", "login", "hunter", "google", "apple", "linux", "ubuntu", "debian"]

  sequences = ["abcdefghijklmnopqrstuvwxyz", "0123456789", "qwertyuiop", "asdfghjkl", "zxcvbnm", "1234567890"]

type
  PwnedConfig* = object
    enabled*: bool
    baseUrl*: string
    timeoutMs*: int

  Verdict* = object
    problem*: string               ## "" when the password is accepted
    code*: string                  ## `weak_password` or `pwned_password` when it is not
    breachCheck*: string           ## `hibp` (the service was asked), `local` (only the local rules were applied: they refused it, or the service did not answer), `off`

func pwnedConfigFromEnv*(): PwnedConfig =
  PwnedConfig(enabled: getEnv("CINIM_PWNED_CHECK", "on") != "off", baseUrl: getEnv("CINIM_PWNED_URL", defaultPwnedUrl),
              timeoutMs: (try: parseInt(getEnv("CINIM_PWNED_TIMEOUT_MS", $defaultPwnedTimeoutMs)) except ValueError: defaultPwnedTimeoutMs))

# ------------------------------------------------------------------ the local rules

func isStep(a, b: char): bool =
  ## b follows a, or precedes it, on the alphabet, the digits or a row of the keyboard (the digits go round: 9 then 0), or is the same character
  if a == b: return true
  for s in sequences:
    let i = s.find(a)
    if i < 0: continue
    if i + 1 < s.len and s[i + 1] == b: return true
    if i > 0 and s[i - 1] == b: return true
  (a == '9' and b == '0') or (a == '0' and b == '9')

func smallestPeriod(r: seq[Rune]): int =
  ## the shortest p such that the text is its first p characters repeated (the last repetition may be cut short); the length when there is none
  for p in 1 ..< r.len:
    var same = true
    for i in p ..< r.len:
      if r[i] != r[i - p]:
        same = false
        break
    if same: return p
  r.len

func withoutCommonWords(lower: string): tuple[found: bool, rest: string] =
  ## the text with every common word (the longest first) taken out, and then every digit and punctuation mark: what remains is the letters nobody has explained;
  ## `found` tells that there was a common word in it (a string of random digits has none, and is not "made of common words")
  var words = @commonWords
  words.sort(proc (a, b: string): int = cmp(b.len, a.len))
  var s = lower
  var changed = true
  while changed:
    changed = false
    for w in words:
      if w in s:
        s = s.replace(w, "")
        changed = true
        result.found = true
  for ch in s:
    if ch in {'a' .. 'z'}: result.rest.add ch

func localProblem*(password: string): string =
  ## "" when the local rules find nothing; otherwise why the password is too simple
  let runes = password.toLower.toRunes
  if runes.len == 0: return "the password is empty"
  var seen: Table[Rune, bool]
  for r in runes: seen[r] = true
  if seen.len < minDistinct:
    return "the password uses too few different characters (" & $seen.len & "; at least " & $minDistinct & " are needed)"
  if smallestPeriod(runes) * 2 <= runes.len:
    return "the password is a short group of characters repeated"
  let lower = password.toLower
  var ascii = true
  for ch in lower:
    if ord(ch) > 127: ascii = false
  if ascii:
    var steps = 0
    for i in 1 ..< lower.len:
      if isStep(lower[i - 1], lower[i]): inc steps
    if lower.len > 1 and steps.float / (lower.len - 1).float >= neighbourShare:
      return "the password is a run of neighbouring characters (like 1234… or qwerty…)"
    let w = withoutCommonWords(lower)
    if w.found and w.rest.len <= leftoverLetters:
      return "the password is made of common words and digits"

# ------------------------------------------------------------------ Pwned Passwords

func sha1Hex*(password: string): string =
  ## upper case, 40 digits, as the service writes them
  const digits = "0123456789ABCDEF"
  for b in sha1(password):
    result.add digits[int(b shr 4)]
    result.add digits[int(b and 15)]

func parseRange*(body, suffix: string): int64 =
  ## how many times the service saw the hash that ends in `suffix`: the answer is lines `SUFFIX:COUNT` (padding lines have the count 0); 0 when it is not there
  for line in body.splitLines:
    let colon = line.find(':')
    if colon <= 0: continue
    if cmpIgnoreCase(line[0 ..< colon].strip, suffix) == 0:
      return try: parseBiggestInt(line[colon + 1 .. ^1].strip) except ValueError: 0
  0

proc pwnedCount*(cfg: PwnedConfig; password: string): tuple[ok: bool, count: int64] =
  ## `ok` is false when the service could not be asked or did not give a good answer
  let h = sha1Hex(password)
  try:
    let client = newHttpClient(timeout = cfg.timeoutMs, headers = newHttpHeaders({"Add-Padding": "true", "User-Agent": "cinim-core"}))
    defer: client.close()
    let r = client.get(cfg.baseUrl & h[0 ..< 5])
    if r.code.int != 200: return
    result = (true, parseRange(r.body, h[5 .. ^1]))
  except CatchableError, OSError:
    discard

proc checkPassword*(cfg: PwnedConfig; password: string): Verdict =
  ## the local rules first (they need nothing), then the service
  let local = localProblem(password)
  if local.len > 0:
    return Verdict(problem: local, code: "weak_password", breachCheck: "local")
  if not cfg.enabled: return Verdict(breachCheck: "off")
  let p = pwnedCount(cfg, password)
  if not p.ok: return Verdict(breachCheck: "local")
  if p.count > 0:
    return Verdict(problem: "this password appears " & $p.count & " times in known data breaches (haveibeenpwned.com); choose another", code: "pwned_password",
                   breachCheck: "hibp")
  Verdict(breachCheck: "hibp")
