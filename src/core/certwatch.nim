## The files of the keys of the channels (`<certs>/tls`) looked at again and again, so that a certificate renewed by cert-manager (or put there by a person) is taken up without a restart of the core.
## `checkCerts` is called by the watchdog loop of the core (`main.nim` `runWatchdog`, every few seconds) and does its work at most every `CINIM_CERT_RELOAD_SECONDS` (60; 0: never). When the files have
## changed and the new set can be used (it is read by the same code that the servers use), `certGeneration` (grpcserve.nim) is raised: the servers of the channels start again with the new files, and the
## clients, which read their files at every connection (common/corechannel.nim), take up the new client pair when they connect again. A set that cannot be used (a half-written file, a key that is not
## the certificate's) is told once and not taken: the old one goes on. The master secret is not in these files and is not reloaded.
import std/[os, atomics, strutils, times]
import checksums/sha2
import grpcserve

type CertWatch* = object
  known: string        ## the fingerprint of the files that are in use
  refused: string      ## the fingerprint of a set that was told to be unusable, so that it is told once
  lastLook: float

proc certFingerprint*(certs: string): string =
  ## a digest of the contents of the files, and "" if one is not there or cannot be read
  var all = ""
  for name in ["ca.pem", "core.pem", "core.key", "client.pem", "client.key"]:
    try: all.add readFile(certs / "tls" / name) & "\0"
    except IOError: return ""
  for c in secureHash(Sha_256, all): result.add toHex(ord(c), 2).toLowerAscii

proc reloadSecondsFromEnv*(): float =
  try: parseFloat(getEnv("CINIM_CERT_RELOAD_SECONDS", "60")) except ValueError: 60.0

proc checkCerts*(w: var CertWatch; certs: string; every: float; now = epochTime()): bool =
  ## true when the keys have changed and `certGeneration` was raised. Cheap to call often.
  if every <= 0 or now - w.lastLook < every and w.known.len > 0: return false
  w.lastLook = now
  let fp = certFingerprint(certs)
  if fp.len == 0: return false                   # being replaced: the next look
  if w.known.len == 0:
    w.known = fp
    return false
  if fp == w.known: return false
  try:
    discard serverTls(certs)                     # can the servers use them
    discard clientTls(certs)
  except CatchableError as e:
    if fp != w.refused:
      w.refused = fp
      stderr.writeLine "core: the files of the keys in " & (certs / "tls") & " changed and cannot be used, the old ones stay in use: " & e.msg
    return false
  w.known = fp
  w.refused = ""
  certGeneration.atomicInc
  echo "core: the files of the keys in ", certs / "tls", " changed: the channels start again with the new ones"
  true
