## The card, through PKCS#11 (OpenSC's `opensc-pkcs11.so` for a SmartCard-HSM, or SoftHSM2's for a test): what the key service needs of it and nothing more. The master key is a private EC
## key on the token; the service asks it for ECDH with a point (`C_DeriveKey`, mechanism ECDH1-DERIVE, no key derivation function) and reads the shared secret; it never asks for anything else.
##
## The PIN is read from a file, once, at the start, and used to log in; it is never put in an argument or in the environment. A PIN that the token refuses is not tried again: the token
## blocks after a few wrong tries (3 on the card), so after one refusal the service says `locked` until it is started again with the right PIN. A removed token or a closed session is
## opened again at the next call; that is `retry` for the caller.
## The module is loaded with `dlopen`, so the program is built dynamically (not the static musl binary of the other components). The list of functions that the module returns is
## checked against the exported symbols of the same names before it is used: a layout that is not the one assumed here would call the wrong function.
import std/[dynlib, locks, strutils, os]

type
  CkRv = culong
  CkAttribute {.pure.} = object
    attrType: culong
    value: pointer
    valueLen: culong
  CkMechanism {.pure.} = object
    mechanism: culong
    parameter: pointer
    parameterLen: culong
  CkEcdh1DeriveParams {.pure.} = object
    kdf: culong
    sharedDataLen: culong
    sharedData: pointer
    publicDataLen: culong
    publicData: pointer
  CkTokenInfo {.pure.} = object
    label: array[32, char]
    manufacturerId: array[32, char]
    model: array[16, char]
    serialNumber: array[16, char]
    flags, maxSessionCount, sessionCount, maxRwSessionCount, rwSessionCount, maxPinLen, minPinLen: culong
    totalPublicMemory, freePublicMemory, totalPrivateMemory, freePrivateMemory: culong
    hardwareVersion, firmwareVersion: array[2, byte]
    utcTime: array[16, char]

  P = pointer
  CkFunctionList {.pure.} = object
    version: array[2, byte]
    cInitialize: proc (args: pointer): CkRv {.cdecl.}
    cFinalize: P
    cGetInfo: P
    cGetFunctionList: P
    cGetSlotList: proc (tokenPresent: byte; list: ptr culong; count: ptr culong): CkRv {.cdecl.}
    cGetSlotInfo: P
    cGetTokenInfo: proc (slot: culong; info: ptr CkTokenInfo): CkRv {.cdecl.}
    cGetMechanismList: P
    cGetMechanismInfo: P
    cInitToken: P
    cInitPin: P
    cSetPin: P
    cOpenSession: proc (slot, flags: culong; app: pointer; notify: pointer; session: ptr culong): CkRv {.cdecl.}
    cCloseSession: proc (session: culong): CkRv {.cdecl.}
    cCloseAllSessions: P
    cGetSessionInfo: P
    cGetOperationState: P
    cSetOperationState: P
    cLogin: proc (session, userType: culong; pin: pointer; pinLen: culong): CkRv {.cdecl.}
    cLogout: proc (session: culong): CkRv {.cdecl.}
    cCreateObject: P
    cCopyObject: P
    cDestroyObject: proc (session, obj: culong): CkRv {.cdecl.}
    cGetObjectSize: P
    cGetAttributeValue: proc (session, obj: culong; template0: ptr CkAttribute; count: culong): CkRv {.cdecl.}
    cSetAttributeValue: P
    cFindObjectsInit: proc (session: culong; template0: ptr CkAttribute; count: culong): CkRv {.cdecl.}
    cFindObjects: proc (session: culong; objs: ptr culong; maxCount: culong; found: ptr culong): CkRv {.cdecl.}
    cFindObjectsFinal: proc (session: culong): CkRv {.cdecl.}
    cEncryptInit, cEncrypt, cEncryptUpdate, cEncryptFinal, cDecryptInit, cDecrypt, cDecryptUpdate, cDecryptFinal: P
    cDigestInit, cDigest, cDigestUpdate, cDigestKey, cDigestFinal: P
    cSignInit, cSign, cSignUpdate, cSignFinal, cSignRecoverInit, cSignRecover: P
    cVerifyInit, cVerify, cVerifyUpdate, cVerifyFinal, cVerifyRecoverInit, cVerifyRecover: P
    cDigestEncryptUpdate, cDecryptDigestUpdate, cSignEncryptUpdate, cDecryptVerifyUpdate: P
    cGenerateKey, cGenerateKeyPair, cWrapKey, cUnwrapKey: P
    cDeriveKey: proc (session: culong; mech: ptr CkMechanism; baseKey: culong; template0: ptr CkAttribute; count: culong; key: ptr culong): CkRv {.cdecl.}
    cSeedRandom, cGenerateRandom, cGetFunctionStatus, cCancelFunction, cWaitForSlotEvent: P

const
  ckrOk = 0.culong
  ckrDeviceError = 0x30.culong
  ckrDeviceRemoved = 0x32.culong
  ckrPinIncorrect = 0xA0.culong
  ckrPinLenRange = 0xA2.culong
  ckrPinLocked = 0xA4.culong
  ckrSessionClosed = 0xB1.culong
  ckrSessionHandleInvalid = 0xB3.culong
  ckrTokenNotPresent = 0xE0.culong
  ckrTokenNotRecognized = 0xE1.culong
  ckrUserAlreadyLoggedIn = 0x100.culong
  ckrUserNotLoggedIn = 0x101.culong
  ckrCryptokiAlreadyInitialized = 0x191.culong
  ckfSerialSession = 4.culong
  ckuUser = 1.culong
  ckoPublicKey = 2.culong
  ckoPrivateKey = 3.culong
  ckoSecretKey = 4.culong
  ckkGenericSecret = 0x10.culong
  ckaClass = 0x0.culong
  ckaToken = 0x1.culong
  ckaValue = 0x11.culong
  ckaKeyType = 0x100.culong
  ckaId = 0x102.culong
  ckaSensitive = 0x103.culong
  ckaExtractable = 0x162.culong
  ckaEcPoint = 0x181.culong
  ckmEcdh1Derive = 0x1050.culong
  ckdNull = 1.culong

type
  P11Config* = object
    module*: string            ## the path of the PKCS#11 library
    tokenLabel*: string        ## the label of the token to use ("cinim"); the first token present when empty
    keyId*: string             ## the CKA_ID of the master key pair, in hex
    pin*: string               ## the user PIN (read from a file by the caller)

  P11Result* = tuple[ok, retry: bool, error: string, value: string]

  Card = object
    lock: Lock
    cfg: P11Config
    lib: LibHandle
    fl: ptr CkFunctionList
    initialised: bool
    slot: culong
    session: culong
    haveSession: bool
    loggedIn: bool
    pinRefused: bool           ## the token said the PIN is wrong: no more tries until the service is started again
    masterPoint: string

var card: Card
initLock(card.lock)

func failure(retry: bool; error: string): P11Result = (false, retry, error, "")

func rvText(rv: CkRv): string =
  case rv
  of ckrPinIncorrect: "the token refused the PIN"
  of ckrPinLocked: "the PIN of the token is blocked"
  of ckrPinLenRange: "the PIN has a length the token does not accept"
  of ckrTokenNotPresent: "no token in the reader"
  of ckrDeviceRemoved: "the token was removed"
  of ckrDeviceError: "the device failed"
  else: "PKCS#11 error 0x" & toHex(BiggestInt(rv), 4)

func attr(t: culong; v: pointer; n: int): CkAttribute = CkAttribute(attrType: t, value: v, valueLen: culong(n))

func unhex(s: string): string =
  var i = 0
  while i + 1 < s.len:
    result.add char(parseHexInt(s[i .. i + 1]))
    i += 2

proc checkLayout(lib: LibHandle; fl: ptr CkFunctionList): string =
  ## the entries that are used must be the module's own exports of the same names; "" when they are
  proc same(name: string; p: pointer): string =
    let a = symAddr(lib, name)
    if a == nil or a != p: name else: ""
  for e in [same("C_Initialize", cast[pointer](fl.cInitialize)), same("C_GetSlotList", cast[pointer](fl.cGetSlotList)), same("C_GetTokenInfo", cast[pointer](fl.cGetTokenInfo)),
            same("C_OpenSession", cast[pointer](fl.cOpenSession)), same("C_CloseSession", cast[pointer](fl.cCloseSession)), same("C_Login", cast[pointer](fl.cLogin)),
            same("C_Logout", cast[pointer](fl.cLogout)), same("C_DestroyObject", cast[pointer](fl.cDestroyObject)), same("C_GetAttributeValue", cast[pointer](fl.cGetAttributeValue)),
            same("C_FindObjectsInit", cast[pointer](fl.cFindObjectsInit)), same("C_FindObjects", cast[pointer](fl.cFindObjects)), same("C_FindObjectsFinal", cast[pointer](fl.cFindObjectsFinal)),
            same("C_DeriveKey", cast[pointer](fl.cDeriveKey)), same("C_GetFunctionList", fl.cGetFunctionList)]:
    if e.len > 0: return e

proc labelOf(info: CkTokenInfo): string =
  for c in info.label: result.add c
  result = result.strip

proc closeSessionLocked() =
  if card.haveSession:
    discard card.fl.cCloseSession(card.session)
    card.haveSession = false
    card.loggedIn = false

proc findSlot(): P11Result =
  var count: culong
  var rv = card.fl.cGetSlotList(1, nil, addr count)
  if rv != ckrOk: return failure(true, rvText(rv))
  if count == 0: return failure(true, rvText(ckrTokenNotPresent))
  var slots = newSeq[culong](int(count))
  rv = card.fl.cGetSlotList(1, addr slots[0], addr count)
  if rv != ckrOk: return failure(true, rvText(rv))
  for i in 0 ..< int(count):
    var info: CkTokenInfo
    if card.fl.cGetTokenInfo(slots[i], addr info) != ckrOk: continue
    if card.cfg.tokenLabel.len == 0 or labelOf(info) == card.cfg.tokenLabel or labelOf(info).startsWith(card.cfg.tokenLabel & " "):
      card.slot = slots[i]
      return (true, false, "", "")
  failure(true, "no token with the label '" & card.cfg.tokenLabel & "' in the reader")

proc findObject(klass: culong): tuple[ok: bool, handle: culong, error: string] =
  let id = unhex(card.cfg.keyId)
  var k = klass
  var tmpl = [attr(ckaClass, addr k, sizeof(culong)), attr(ckaId, (if id.len > 0: unsafeAddr id[0] else: nil), id.len)]
  var rv = card.fl.cFindObjectsInit(card.session, addr tmpl[0], 2)
  if rv != ckrOk: return (false, 0.culong, rvText(rv))
  var h: culong
  var n: culong
  rv = card.fl.cFindObjects(card.session, addr h, 1, addr n)
  discard card.fl.cFindObjectsFinal(card.session)
  if rv != ckrOk: return (false, 0.culong, rvText(rv))
  if n == 0: return (false, 0.culong, "the token has no such key (id " & card.cfg.keyId & ")")
  (true, h, "")

proc ensureSession(login: bool): P11Result =
  if not card.initialised: return failure(false, "the module is not loaded")
  if card.haveSession and (not login or card.loggedIn): return (true, false, "", "")
  if not card.haveSession:
    let s = findSlot()
    if not s.ok: return s
    var h: culong
    let rv = card.fl.cOpenSession(card.slot, ckfSerialSession, nil, nil, addr h)
    if rv != ckrOk: return failure(true, rvText(rv))
    card.session = h
    card.haveSession = true
    card.loggedIn = false
  if login and not card.loggedIn:
    if card.pinRefused: return failure(true, "the token refused the PIN earlier: not tried again (start the service with the right PIN)")
    let pin = card.cfg.pin
    let rv = card.fl.cLogin(card.session, ckuUser, (if pin.len > 0: unsafeAddr pin[0] else: nil), culong(pin.len))
    if rv == ckrUserAlreadyLoggedIn or rv == ckrOk:
      card.loggedIn = true
    elif rv == ckrPinIncorrect or rv == ckrPinLocked or rv == ckrPinLenRange:
      card.pinRefused = true
      return failure(true, rvText(rv))
    else:
      closeSessionLocked()
      return failure(true, rvText(rv))
  (true, false, "", "")

proc p11Open*(cfg: P11Config): P11Result =
  ## loads the module and starts it; the token itself is looked for at the first call, so a service can start with the card out
  withLock card.lock:
    card.cfg = cfg
    card.pinRefused = false
    closeSessionLocked()
    if not card.initialised:
      card.lib = loadLib(cfg.module)
      if card.lib == nil: return failure(false, "cannot load " & cfg.module)
      let getList = cast[proc (list: ptr ptr CkFunctionList): CkRv {.cdecl.}](symAddr(card.lib, "C_GetFunctionList"))
      if getList == nil: return failure(false, "no C_GetFunctionList in " & cfg.module)
      var fl: ptr CkFunctionList
      if getList(addr fl) != ckrOk or fl == nil: return failure(false, "C_GetFunctionList failed")
      let bad = checkLayout(card.lib, fl)
      if bad.len > 0: return failure(false, "the function list of the module does not have the layout this service assumes (" & bad & "): refusing to use it")
      card.fl = fl
      let rv = fl.cInitialize(nil)
      if rv != ckrOk and rv != ckrCryptokiAlreadyInitialized: return failure(false, "C_Initialize: " & rvText(rv))
      card.initialised = true
  (true, false, "", "")

proc p11MasterPoint*(): P11Result =
  ## the public half of the master key: the 65 bytes of its point, read from the token (no PIN needed); kept after the first reading
  withLock card.lock:
    if card.masterPoint.len == 65: return (true, false, "", card.masterPoint)
    let s = ensureSession(false)
    if not s.ok: return s
    let o = findObject(ckoPublicKey)
    if not o.ok: return failure(false, o.error)
    var a = attr(ckaEcPoint, nil, 0)
    if card.fl.cGetAttributeValue(card.session, o.handle, addr a, 1) != ckrOk or a.valueLen == 0: return failure(true, "cannot read the public key")
    var buf = newString(int(a.valueLen))
    a.value = addr buf[0]
    let rv = card.fl.cGetAttributeValue(card.session, o.handle, addr a, 1)
    if rv != ckrOk: return failure(true, rvText(rv))
    # CKA_EC_POINT is a DER OCTET STRING around the point (04 41 04 ...); some modules give the point itself
    var point = buf
    if point.len == 67 and point[0] == '\x04' and point[1] == '\x41': point = point[2 .. ^1]
    if point.len != 65 or point[0] != '\x04': return failure(false, "the public key is not an uncompressed P-256 point")
    card.masterPoint = point
    result = (true, false, "", point)

proc p11Derive*(peerPoint: string): P11Result =
  ## ECDH of the master private key with a point: the 32 bytes of the shared secret (a PIN, a login, the token's private operation)
  withLock card.lock:
    let s = ensureSession(true)
    if not s.ok: return s
    let o = findObject(ckoPrivateKey)
    if not o.ok: return failure(false, o.error)
    var params = CkEcdh1DeriveParams(kdf: ckdNull, sharedDataLen: 0, sharedData: nil, publicDataLen: culong(peerPoint.len), publicData: unsafeAddr peerPoint[0])
    var mech = CkMechanism(mechanism: ckmEcdh1Derive, parameter: addr params, parameterLen: culong(sizeof(params)))
    var klass = ckoSecretKey
    var ktype = ckkGenericSecret
    var no: byte = 0
    var yes: byte = 1
    var tmpl = [attr(ckaClass, addr klass, sizeof(culong)), attr(ckaKeyType, addr ktype, sizeof(culong)), attr(ckaToken, addr no, 1),
                attr(ckaSensitive, addr no, 1), attr(ckaExtractable, addr yes, 1)]
    var key: culong
    let rv = card.fl.cDeriveKey(card.session, addr mech, o.handle, addr tmpl[0], culong(tmpl.len), addr key)
    if rv != ckrOk:
      if rv in [ckrSessionClosed, ckrSessionHandleInvalid, ckrUserNotLoggedIn, ckrDeviceRemoved, ckrTokenNotPresent, ckrDeviceError, ckrTokenNotRecognized]:
        closeSessionLocked()
        return failure(true, rvText(rv))
      return failure(rv != 0x12.culong and rv != 0x13.culong, rvText(rv))      # a point the token refuses (invalid, 0x12/0x13 attribute errors) is final; the rest may pass
    var a = attr(ckaValue, nil, 0)
    var secret = ""
    if card.fl.cGetAttributeValue(card.session, key, addr a, 1) == ckrOk and a.valueLen > 0:
      secret = newString(int(a.valueLen))
      a.value = addr secret[0]
      if card.fl.cGetAttributeValue(card.session, key, addr a, 1) != ckrOk: secret = ""
    discard card.fl.cDestroyObject(card.session, key)
    if secret.len != 32: return failure(true, "the token gave a shared secret of " & $secret.len & " bytes, not 32")
    result = (true, false, "", secret)

proc p11Locked*(): bool =
  withLock card.lock: result = card.pinRefused

proc p11Close*() =
  withLock card.lock:
    if card.haveSession:
      discard card.fl.cLogout(card.session)
      closeSessionLocked()
