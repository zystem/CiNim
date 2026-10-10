## The hash chain of a run's journal, kept by the core (T-03, PIP-003, docs/conductors.md section 7). Pure.
##
## Every row of `run_journal` carries `hash = SHA-256(previous hash, seq, kind, payload, result)` (the function of executor/journal.nim, so an
## executor that is given the rows can check them with the code it already has), and the run keeps the hash of its newest row (`runs.journal_tip`).
## The core writes the rows and checks the chain at every lease; the executor, which may run in a tenant's namespace, writes nothing. The tip
## catches the removal of the newest rows (a step would be done again). An attacker who can write the database *and* knows the function can
## rebuild a whole chain: the chain is evidence of tampering by anyone who cannot, not a defence against the owner of the database.
import std/strutils
import ../executor/journal as jr

type
  Row* = object
    seq*: int
    kind*, payload*, result*, hash*: string
  ChainVerdict* = enum
    cvOk
    cvBroken
  ChainCheck* = object
    verdict*: ChainVerdict
    at*: int          ## the sequence number where it broke (-1: no particular row)
    why*: string

proc chainHash*(prev: string; r: Row): string =
  jr.entryHash(prev, jr.Entry(seq: r.seq, kind: r.kind, payload: r.payload, result: r.result))

proc checkChain*(rows: seq[Row]; tip: string): ChainCheck =
  ## `rows` in the order of `seq`; `tip` is the hash the run keeps of its newest row
  if rows.len == 0:
    return if tip.len == 0: ChainCheck(verdict: cvOk, at: -1) else: ChainCheck(verdict: cvBroken, at: -1, why: "the journal is empty but the run has a tip")
  var hashed = 0
  for r in rows:
    if r.hash.len > 0: inc hashed
  if hashed != rows.len: return ChainCheck(verdict: cvBroken, at: -1, why: "some rows of the journal have no hash")
  var prev = ""
  for i, r in rows:
    if r.seq != i: return ChainCheck(verdict: cvBroken, at: r.seq, why: "the journal has a gap or a repeated number at " & $r.seq)
    if r.hash != chainHash(prev, r): return ChainCheck(verdict: cvBroken, at: r.seq, why: "the hash of record " & $r.seq & " does not match its content")
    prev = r.hash
  if tip != prev: return ChainCheck(verdict: cvBroken, at: -1, why: "the newest records of the journal are missing or changed")
  ChainCheck(verdict: cvOk, at: -1)
