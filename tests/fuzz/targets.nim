## The parsers that are fuzzed (SEC-009), each with the seeds that its own encoders make and a `call` that takes bytes: true when they were taken, false when the parser refused them in the way
## it promises (a result that says no, or its own exception, which `call` catches); any other exception, a Defect, a crash or a sanitizer report escapes, and is a find.
## Two users: tests/unit/tfuzz.nim (a mutation fuzzer in plain Nim, in the ordinary suite, tests/support/fuzz.nim) and tests/fuzz/harness.nim (libFuzzer with clang and AddressSanitizer,
## tools/test/fuzz.sh). One list, so that the two cannot drift apart.
import std/[json, options, strutils, sequtils]
import protobuf_serialization
import protobuf_serialization/files/type_generator
import common/[ldapclient, stream, runpipe]
import core/webauthn
import ../../build/nimproto/protos
import ../support/fakeauthn

type
  FuzzTarget* = object
    name*: string
    seeds*: seq[string]
    call*: proc (input: string): bool {.closure.}
    strict*: bool              ## a check that vouches for something (a signature, a key): it must say no to every input that is not one of the seeds

proc bytesOf(s: string): seq[byte] =
  for c in s: result.add byte(c)

proc strOf(b: seq[byte]): string =
  for x in b: result.add char(x)

proc ldapSeeds(): tuple[messages, filters, urls: seq[string]] =
  let bindOk = tlv(0x30, berInt(1) & tlv(0x61, tlv(0x0a, "\x00") & tlv(0x04, "") & tlv(0x04, "")))
  let bindBad = tlv(0x30, berInt(2) & tlv(0x61, tlv(0x0a, "\x31") & tlv(0x04, "") & tlv(0x04, "Invalid credentials")))
  let entry = tlv(0x30, berInt(3) & tlv(0x64, tlv(0x04, "uid=ann,ou=people,dc=example,dc=org") &
    tlv(0x30, tlv(0x30, tlv(0x04, "cn") & tlv(0x31, tlv(0x04, "Ann") & tlv(0x04, "Ann Lee"))) & tlv(0x30, tlv(0x04, "mail") & tlv(0x31, tlv(0x04, "ann@example.org"))))))
  let done = tlv(0x30, berInt(3) & tlv(0x65, tlv(0x0a, "\x00") & tlv(0x04, "") & tlv(0x04, "")))
  let big = tlv(0x30, berInt(100_000) & tlv(0x65, tlv(0x0a, "\x00") & tlv(0x04, "") & tlv(0x04, repeat('x', 300))))     # a long form of the length
  result.messages = @[bindOk, bindBad, entry, done, big]
  result.filters = @["(uid=ann)", "(&(objectClass=person)(|(uid=ann)(cn=Ann*))(!(disabled=1)))", "(member=cn=a\\2ab,dc=x)", "(mail=*@example.org)", "(cn=*)", "(|(a=1)(b=2)(c=3))"]
  result.urls = @["ldap://dc1.example.org", "ldaps://dc1.example.org:636", "ldap://[::1]:389", "ldaps://host"]

type Webauthn* = object
  ## a registered software key and what it sent: the inputs of the security-key targets
  cfg*: WebauthnConfig
  attestation*, clientCreate*, clientGet*, authData*, signature*: string
  registered*: Checked

proc newWebauthn*(): Webauthn =
  result.cfg = WebauthnConfig(rpId: "ci.example.org", rpName: "CiNim", origins: @["https://ci.example.org"])
  var auth = newAuthenticator()
  let created = auth.create(result.cfg.rpId, "https://ci.example.org", "challenge-1")
  result.attestation = unb64url(created["attestationObject"].getStr).data
  result.clientCreate = unb64url(created["clientDataJSON"].getStr).data
  result.registered = checkRegistration(result.cfg, result.clientCreate, result.attestation)
  let got = auth.get(result.cfg.rpId, "https://ci.example.org", "challenge-2")
  result.clientGet = unb64url(got["clientDataJSON"].getStr).data
  result.authData = unb64url(got["authenticatorData"].getStr).data
  result.signature = unb64url(got["signature"].getStr).data

proc allTargets*(): seq[FuzzTarget] =
  let l = ldapSeeds()
  result.add FuzzTarget(name: "ldap_message", seeds: l.messages, call: proc (s: string): bool =
    try:
      let a = parseMessage(s)
      case a.op
      of 0x61, 0x65: discard parseResult(a.body)
      of 0x64: discard parseEntry(a.body)
      else: discard
      true
    except LdapError: false)
  let resultBodies = l.messages.filterIt(parseMessage(it).op != 0x64).mapIt(parseMessage(it).body)
  let entryBodies = l.messages.filterIt(parseMessage(it).op == 0x64).mapIt(parseMessage(it).body)
  result.add FuzzTarget(name: "ldap_result", seeds: resultBodies, call: proc (s: string): bool =
    try: discard parseResult(s); true
    except LdapError: false)
  result.add FuzzTarget(name: "ldap_entry", seeds: entryBodies, call: proc (s: string): bool =
    try: discard parseEntry(s); true
    except LdapError: false)
  result.add FuzzTarget(name: "ldap_filter", seeds: l.filters, call: proc (s: string): bool =
    try: discard encodeFilter(s); true
    except LdapError: false)
  result.add FuzzTarget(name: "ldap_url", seeds: l.urls, call: proc (s: string): bool =
    try: checkLdapUrl(s); true
    except LdapError: false)

  let w = newWebauthn()
  var pos0 = 0
  let ad = parseCbor(w.attestation, pos0).value.mapGet(Cbor(kind: ckText, text: "authData")).bytes
  # the seeds of CBOR: the attestation object, a map of a few kinds of item, and the COSE key that ends the authenticator data
  result.add FuzzTarget(name: "cbor", seeds: @[w.attestation, "\xa3\x61\x61\x26\x03\x42xy\x64list\x83\x01\x02\x03", ad[55 + 32 .. ^1]], call: proc (s: string): bool =
    var pos = 0
    let r = parseCbor(s, pos)
    doAssert pos <= s.len
    r.ok)
  result.add FuzzTarget(name: "authenticator_data", seeds: @[ad, w.authData], call: proc (s: string): bool = parseAuthData(s).ok)
  result.add FuzzTarget(name: "registration_attestation", seeds: @[w.attestation], call: proc (s: string): bool =
    let c = checkRegistration(w.cfg, w.clientCreate, s)
    doAssert c.ok or c.error.len > 0
    c.ok)
  result.add FuzzTarget(name: "registration_client_data", seeds: @[w.clientCreate], call: proc (s: string): bool =
    let c = checkRegistration(w.cfg, s, w.attestation)
    doAssert c.ok or c.error.len > 0
    c.ok)
  result.add FuzzTarget(name: "assertion_signature", strict: true, seeds: @[w.signature], call: proc (s: string): bool =
    let c = checkAssertion(w.cfg, w.registered.credential, w.clientGet, w.authData, s)
    doAssert c.ok or c.error.len > 0
    c.ok)
  result.add FuzzTarget(name: "assertion_authenticator_data", strict: true, seeds: @[w.authData], call: proc (s: string): bool =
    let c = checkAssertion(w.cfg, w.registered.credential, w.clientGet, s, w.signature)
    doAssert c.ok or c.error.len > 0
    c.ok)
  result.add FuzzTarget(name: "assertion_client_data", strict: true, seeds: @[w.clientGet], call: proc (s: string): bool =
    let c = checkAssertion(w.cfg, w.registered.credential, s, w.authData, w.signature)
    doAssert c.ok or c.error.len > 0
    c.ok)
  let msg = w.authData & sha256Raw(w.clientGet)
  result.add FuzzTarget(name: "verify_signature", strict: true, seeds: @[w.signature], call: proc (s: string): bool =
    verifyEs256(w.registered.credential.x, w.registered.credential.y, msg, s))
  result.add FuzzTarget(name: "verify_key", strict: true, seeds: @[w.registered.credential.x & w.registered.credential.y], call: proc (s: string): bool =
    let half = s.len div 2
    verifyEs256(s[0 ..< half], s[half .. ^1], msg, w.signature))
  result.add FuzzTarget(name: "base64url", seeds: @[b64url(w.attestation), "YQ", "-__-", ""], call: proc (s: string): bool =
    let r = unb64url(s)
    if r.ok: doAssert unb64url(b64url(r.data)).data == r.data         # what is read is stable (a trailing bit that is not 0 is read and not kept: "-_" and "-w" are one byte)
    r.ok)

  let frames = @[
    encodeFrame(frame("sess-1", "controller.report", "payload", id = 7, ack = 3, re = 0)),
    encodeFrame(frame("s", "ping", "", ack = 1'u64 shl 40)),
    encodeFrame(frame("sess-2", "controller.work", repeat('x', 300), id = 1, re = 7, key = "org-ns")),
    encodeFrame(frame("", "", ""))]
  result.add FuzzTarget(name: "stream_frame", seeds: frames, call: proc (s: string): bool =
    let f = decodeFrame(s)
    if f.isNone: return false
    let again = decodeFrame(encodeFrame(f.get))
    doAssert again.isSome and again.get == f.get
    true)
  let pipes = @[encodePipe(pkLease, "lease"), encodePipe(pkCall, repeat('c', 70)) & encodePipe(pkReply, "r") & encodePipe(pkFinish, ""), encodePipe(pkChecked, repeat('y', 300))]
  result.add FuzzTarget(name: "run_pipe", seeds: pipes, call: proc (s: string): bool =
    var r: PipeReader
    var taken = 0
    let step = 1 + (s.len mod 7)                       # the bytes come in pieces of one size for this input, as they do from a pipe
    var at = 0
    while at < s.len:
      r.feed(s[at ..< min(s.len, at + step)])
      at += step
      while true:
        let f = r.next
        if f.isNone: break
        taken += 5 + f.get.payload.len
    doAssert taken <= s.len
    if r.broken: doAssert r.next.isNone
    taken > 0)

  let reports = @[
    strOf(Protobuf.encode(PollRequest(session_id: "s1", ack_command_seq: 4, free_pod_slots: 3, namespace: "org-a", credential: "cred",
      transitions: @[PodTransition(step: StepRef(run_id: "r1", seq: 2, attempt: 1), pod_name: "p", node: "n", exit_code: -1, termination_reason: "failed")],
      status: ComponentStatus(kind: "job-controller", id: "c1", version: "1", uptime_s: 99)))),
    strOf(Protobuf.encode(PollRequest()))]
  let hellos = @[strOf(Protobuf.encode(ConductorHello(conductor_id: "c1", namespace: "org-a", credential: "x", api_versions: @[1'u32, 2], free_places: 4, held_runs: @["r1", "r2"], image: "img"))),
                 strOf(Protobuf.encode(ConductorHello()))]
  result.add FuzzTarget(name: "pb_poll_request", seeds: reports, call: proc (s: string): bool =
    try: discard Protobuf.decode(bytesOf(s), PollRequest); true
    except CatchableError: false)
  result.add FuzzTarget(name: "pb_conductor_hello", seeds: hellos, call: proc (s: string): bool =
    try: discard Protobuf.decode(bytesOf(s), ConductorHello); true
    except CatchableError: false)
