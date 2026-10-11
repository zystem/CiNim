## IAM-001: the checks of a password a person chose - the local rules, and Pwned Passwords with k-anonymity (against a fake of the service).
import std/[unittest, strutils, net, os]
import ../../src/core/pwcheck

suite "IAM-001 the local rules refuse what a list of breached passwords would hold first":
  test "the same character, a few characters, a short group repeated":
    for pw in ["1111111111111111", "aaaaaaaaaaaaaaaa", "sexsexsexsexsex", "sexsexsexsexsexs", "abababababababab", "1212121212121212", "abcdabcdabcdabcd",
               "0123012301230123", "xK9#mQ2$xK9#mQ2$", "aabbaabbaabbaabb"]:
      check localProblem(pw) != ""
  test "runs of neighbours: the digits, the alphabet, the keyboard, in both directions":
    for pw in ["1234567890123456", "9876543210987654", "abcdefghijklmnop", "ponmlkjihgfedcba", "qwertyuiopasdfgh", "asdfghjklzxcvbnm", "1234567890qwerty0"]:
      check localProblem(pw) != ""
  test "only common words and digits":
    for pw in ["passwordpassword", "password12345678", "iloveyou12345678", "Qwerty-Password-123", "letmeinletmein12", "Administrator-2024!"]:
      check localProblem(pw) != ""
  test "good passwords pass, also those that contain a common word or a few steps":
    for pw in ["correct horse battery staple", "Tr0ub4dor&3-xylophone", "7f3k-Qm92-LpZ8-wX1c", "my dog Rex ate the password", "пароль-с-пробелами-密码",
               "8394027561837402", "3f9a1c07b2d84e55a6c0917d3be2f84a", "purple-elephant-123-tango"]:
      check localProblem(pw) == ""
  test "a password made by the core (256 random bits in hex) passes":
    check localProblem("9c4e1a7b03d85f26a1b7c93e40d6f852" & "7e0a4c9b13d6825fa09e71c4b3d8650f") == ""
  test "an empty one":
    check localProblem("") != ""

suite "IAM-001 the range answer of Pwned Passwords":
  test "the SHA-1 is upper case and 40 digits (a known value)":
    check sha1Hex("password") == "5BAA61E4C9B93F3F0682250B6CF8331B7EE68FD8"
  test "the count of the suffix is read, whatever the case, the line endings and the padding":
    let body = "003D68EB55068C33ACE09247EE4C639306B:3\r\n0018A45C4D1DEF81644B54AB7F969B88D65:1\r\n1E4C9B93F3F0682250B6CF8331B7EE68FD8:9545824\r\nFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF:0\r\n"
    check parseRange(body, "1E4C9B93F3F0682250B6CF8331B7EE68FD8") == 9545824
    check parseRange(body, "1e4c9b93f3f0682250b6cf8331b7ee68fd8") == 9545824
    check parseRange(body, "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF") == 0           # padding
    check parseRange(body, "0000000000000000000000000000000000A") == 0           # not there
    check parseRange("", "1E4C9B93F3F0682250B6CF8331B7EE68FD8") == 0
    check parseRange("garbage\r\n:::\r\nabc:xyz\r\n", "ABC") == 0

# a fake of the service: it answers one request on a port, says what the request was, and then stops
proc requestFile(port: int): string = getTempDir() / ("pwfake-" & $port & ".req")      # what the fake saw: a file, not a string shared between threads

proc fake(arg: tuple[port: int, status: int, body: string, silent: bool]) {.thread.} =
  var s = newSocket()
  s.setSockOpt(OptReuseAddr, true)
  s.bindAddr(Port(arg.port), "127.0.0.1")
  s.listen()
  var c: Socket
  s.accept(c)
  var head = ""
  while not head.endsWith("\r\n\r\n"):
    let ch = c.recv(1, timeout = 2000)
    if ch.len == 0: break
    head.add ch
  writeFile(requestFile(arg.port), head)
  if arg.silent: sleep 1500
  else: c.send("HTTP/1.1 " & $arg.status & " X\r\nContent-Type: text/plain\r\nContent-Length: " & $arg.body.len & "\r\nConnection: close\r\n\r\n" & arg.body)
  c.close()
  s.close()

proc askFake(port: int; status: int; body: string; password: string; silent = false; timeoutMs = 3000): tuple[ok: bool, count: int64, request: string] =
  var th: Thread[tuple[port: int, status: int, body: string, silent: bool]]
  createThread(th, fake, (port, status, body, silent))
  sleep 200
  let r = pwnedCount(PwnedConfig(enabled: true, baseUrl: "http://127.0.0.1:" & $port & "/range/", timeoutMs: timeoutMs), password)
  joinThread th
  result = (r.ok, r.count, (try: readFile(requestFile(port)) except IOError: ""))

suite "IAM-001 asking Pwned Passwords":
  test "only the first five digits of the hash are sent, with the padding header, and a match is counted here":
    let h = sha1Hex("hunter2hunter2hunter2")
    let r = askFake(29851, 200, h[5 .. ^1] & ":17\r\nAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA:0\r\n", "hunter2hunter2hunter2")
    check r.ok and r.count == 17
    check r.request.startsWith("GET /range/" & h[0 ..< 5] & " ")
    check h[5 .. ^1] notin r.request and "hunter2" notin r.request
    check "add-padding: true" in r.request.toLowerAscii
  test "a hash that is not in the answer is not pwned":
    let r = askFake(29852, 200, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA:4\r\n", "a-good-long-password-123")
    check r.ok and r.count == 0
  test "an error status, a service that does not answer in time, and one that is not there: not asked, no verdict":
    check not askFake(29853, 503, "busy", "a-good-long-password-123").ok
    check not askFake(29854, 200, "", "a-good-long-password-123", silent = true, timeoutMs = 300).ok
    check not pwnedCount(PwnedConfig(enabled: true, baseUrl: "http://127.0.0.1:29855/range/", timeoutMs: 500), "a-good-long-password-123").ok
  test "an address in the https scheme is not asked without TLS in this build, and that is no verdict either":
    check not pwnedCount(PwnedConfig(enabled: true, baseUrl: "https://127.0.0.1:29856/range/", timeoutMs: 500), "a-good-long-password-123").ok

suite "IAM-001 the verdict":
  proc cfg(port: int; on = true): PwnedConfig = PwnedConfig(enabled: on, baseUrl: "http://127.0.0.1:" & $port & "/range/", timeoutMs: 400)
  test "a simple password is refused by the local rules without asking anyone":
    let v = checkPassword(cfg(29857), "1111111111111111")          # nobody listens: asking would fail, and the answer would be `local` all the same
    check v.problem != "" and v.code == "weak_password" and v.breachCheck == "local"
  test "a password the service knows is refused with the count":
    let pw = "tr0ub4dor-and-3-xylophones"
    var th: Thread[tuple[port: int, status: int, body: string, silent: bool]]
    createThread(th, fake, (29858, 200, sha1Hex(pw)[5 .. ^1] & ":1234\r\n", false))
    sleep 200
    let v = checkPassword(cfg(29858), pw)
    joinThread th
    check v.code == "pwned_password" and "1234 times" in v.problem and v.breachCheck == "hibp"
  test "a password the service does not know is accepted and says it was checked":
    var th: Thread[tuple[port: int, status: int, body: string, silent: bool]]
    createThread(th, fake, (29859, 200, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA:2\r\n", false))
    sleep 200
    let v = checkPassword(cfg(29859), "tr0ub4dor-and-3-xylophones")
    joinThread th
    check v.problem == "" and v.breachCheck == "hibp"
  test "a service that does not answer: accepted on the local rules alone, and the verdict says so":
    let v = checkPassword(cfg(29860), "tr0ub4dor-and-3-xylophones")
    check v.problem == "" and v.breachCheck == "local"
  test "switched off: only the local rules, and the verdict says off":
    let v = checkPassword(cfg(29861, on = false), "tr0ub4dor-and-3-xylophones")
    check v.problem == "" and v.breachCheck == "off"
    check checkPassword(cfg(29861, on = false), "abcdefghijklmnop").code == "weak_password"
