## Password hashing with Argon2id from libsodium (`crypto_pwhash_str`; the minimal static libsodium of tools/image/Dockerfile.deps has it). A password that a person
## chooses is not 256 random bits, so the fast hash of an API token (D-44) is not enough for it: Argon2id is memory-hard and salted, and the stored string holds the
## algorithm, the cost and the salt (`$argon2id$v=19$m=8192,t=16,p=1$...`), so the cost can be changed later and old strings still verify. The cost is **8 MiB and 16 passes**: the product of memory and passes, which is what an attacker pays
## for, is that of libsodium's own default (64 MiB, 2 passes), and OWASP's profiles for Argon2id keep that product near constant (46 MiB x 1 ... 7 MiB x 5). The core is built to be small, and
## 64 MiB per hash would double its memory for the time of a login. Less memory is cheaper for an attacker's GPU than the product says, which the passes make up for only in part; the length rule (16 characters) and the
## check against breached passwords (core/pwcheck.nim) are what keep a guessable password out. One hash is made at a time in the process, so that a flood of logins costs time, not memory.
## A program that imports this module links `-lsodium`.
import std/locks
{.passL: "-lsodium".}

proc sodium_init(): cint {.cdecl, importc.}
proc crypto_pwhash_str(outp: cstring; passwd: cstring; passwdlen: culonglong; opslimit: culonglong; memlimit: csize_t): cint {.cdecl, importc.}
proc crypto_pwhash_str_verify(str: cstring; passwd: cstring; passwdlen: culonglong): cint {.cdecl, importc.}
const
  passes = 16'u64                 ## opslimit of Argon2id is the number of passes
  memoryBytes = 8 * 1024 * 1024   ## memlimit is bytes
proc crypto_pwhash_strbytes(): csize_t {.cdecl, importc.}

var gate: Lock
initLock(gate)

proc passwordHash*(password: string): string {.gcsafe.} =
  ## the string to store
  {.cast(gcsafe).}:
    withLock gate:
      if sodium_init() < 0: raise newException(OSError, "libsodium could not be initialised")
      var buf = newString(int(crypto_pwhash_strbytes()))
      if crypto_pwhash_str(cstring(buf), cstring(password), culonglong(password.len), culonglong(passes), csize_t(memoryBytes)) != 0:
        raise newException(OSError, "out of memory for a password hash")
      result = $cstring(buf)

proc passwordMatches*(stored, password: string): bool {.gcsafe.} =
  ## whether the password is the one the string was made from; false for a string that is not one of ours
  if stored.len == 0 or stored[0] != '$': return false
  {.cast(gcsafe).}:
    withLock gate:
      if sodium_init() < 0: raise newException(OSError, "libsodium could not be initialised")
      result = crypto_pwhash_str_verify(cstring(stored), cstring(password), culonglong(password.len)) == 0
