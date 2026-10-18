## D-61 (docs/storage-module.md, "Direct transfer from the shim"): the artifacts of a step on the core's channel when the shim can send its bytes straight to the storage module. The core
## starts the upload and hands the shim a grant and the path; the shim reports the digest of every part over this channel at put_end, and the core completes the upload only when the module
## has received parts with those digests; a read is offered with a grant as well, and there is no other way (no op carries bytes through the core). Against a real rqlite and a store that is a double in memory. Needs CINIM_RQLITE_URL.
import std/[unittest, json, os, times, tables, strutils, sequtils]
import checksums/sha2
import common/[rqlite, ctrlauth, storagebackend, storagetoken]
import core/[schema, scheduler, loggate, logcircuit, objectstore, artifactingest, storageclient]

let url = getEnv("CINIM_RQLITE_URL")
unenrolledControllers = true

type Mem = ref object of ObjectBackend
  objects: Table[string, string]
  received: seq[PartRecord]                        ## what the module would report for the upload: the parts that came straight to it
  completed: int
  aborted: int
method uploadedParts(b: Mem; key, uploadId: string): tuple[res: Outcome, known: bool, parts: seq[PartRecord]] = (done(), true, b.received)
method createMultipart(b: Mem; key: string): tuple[res: Outcome, uploadId: string] = (done(), "up-" & $b.objects.len)
method completeMultipart(b: Mem; key, uploadId: string; parts: seq[(int, string)]): Outcome =
  inc b.completed
  done()
method abortMultipart(b: Mem; key, uploadId: string): Outcome =
  inc b.aborted
  done()
method objectSize(b: Mem; key: string): tuple[res: Outcome, size: int64] =
  if key in b.objects: (done(), int64(b.objects[key].len)) else: (fail("no such object"), -1'i64)
method putObject(b: Mem; key, data: string): Outcome =
  b.objects[key] = data
  done()
method deleteObject(b: Mem; key: string): Outcome =
  b.objects.del key
  done()

func shaOf(s: string): string =
  for c in secureHash(Sha_256, s): result.add toHex(ord(c), 2).toLowerAscii

suite "D-61 the artifacts of a step, sent straight to the storage module":
  if url.len == 0:
    echo "  skipped: CINIM_RQLITE_URL is not set"
  else:
    var c = newRq(url)
    migrate(c)
    initGate(Watch(disabled: true, cfg: defaultConfig()))
    let defaultProfile = c.seedDefaultProfile("cinim-default-ns")
    let sfx = newId()
    let org = c.addOrganization("da-" & sfx, "DA")
    let ns = "cinim-001-da-" & sfx
    let prof = c.ensureOrganizationProfile(org, ns)
    let co = Core(rqliteUrl: url, profileId: defaultProfile, namespace: "cinim-default-ns")
    let master = "a-master-for-the-direct-artifact-test"
    const secret = "a-secret-of-the-shard-for-grants"
    configureStorage("http://module.test:18090", secret, "001", "http://module.test:18091")
    discard c.execute(%*[["INSERT OR REPLACE INTO org_storage (tenant_id, purpose, store_name, updated_by, updated_at) VALUES (?, 'artifacts', 'mem', 'test', 1)", org]])
    let now = getTime().toUnix()
    let runId = co.createRun("return 1", org, prof)
    let jobId = newId()
    discard c.execute(%*[["INSERT INTO jobs (id, run_id, key, state, profile_id) VALUES (?, ?, 'job-1', 'RUNNING', ?)", jobId, runId, prof]])
    discard c.execute(%*[["INSERT INTO steps (id, run_id, job_id, ordinal, type, state, profile_id, image, command, opts, queued_at, attempt, claimed_at) " &
      "VALUES (?, ?, ?, 0, 'sh', 'RUNNING', ?, 'alpine', 'true', ?, '1', 1, ?)", newId(), runId, jobId, prof,
      """{"artifacts":{"upload":["dist/**"],"download":["dist"]}}""", now]])
    proc req(op, path: string; direct = true): artifactingest.ArtifactRequest =
      artifactingest.ArtifactRequest(step: artifactingest.StepRef(run_id: runId, seq: 0, attempt: 1), job_token: stepToken(master, runId, 0, 1), op: op, path: path, direct: direct)
    let data = "x".repeat(30) & "y".repeat(10)

    test "D-61 put_begin answers with a grant for this upload; a shim that cannot use one, or a shard with no port for shims, is refused (direct_required)":
      let be = Mem(objects: initTable[string, string]())
      var b = req("put_begin", "dist/a.bin")
      b.size = uint64(data.len)
      b.sha256 = shaOf(data)
      let began = handleArtifact(c, b, master, fixedStoreSet(be))
      check began.accepted and began.upload_id.len > 0 and began.direct_url == "http://module.test:18091"
      let key = objectKey(org, runId, "dist/a.bin")
      check began.direct_path == "/s/mem/" & key
      check verifyGrant(secret, "001", "mem", key, began.upload_id, "w", began.grant, now)
      check not verifyGrant(secret, "001", "mem", key, "another-upload", "w", began.grant, now)
      var gone = req("put_abort", "dist/a.bin"); gone.upload_id = began.upload_id
      check handleArtifact(c, gone, master, fixedStoreSet(be)).accepted
      b.direct = false
      let plain = handleArtifact(c, b, master, fixedStoreSet(be))
      check not plain.accepted and plain.failure.code == "direct_required"
      b.direct = true
      configureStorage("http://module.test:18090", secret, "001", "")                                  # a shard that has not the port for shims
      check handleArtifact(c, b, master, fixedStoreSet(be)).failure.code == "direct_required"
      configureStorage("http://module.test:18090", secret, "001", "http://module.test:18091")
      check c.query(%*[["SELECT count(*) FROM artifacts WHERE run_id = ? AND path = 'dist/a.bin'", runId]])["results"][0]["values"][0][0].getInt == 0     # nothing was started
      # the ways that carried bytes are gone
      var part = req("put_part", "dist/a.bin"); part.upload_id = "x"
      check handleArtifact(c, part, master, fixedStoreSet(be)).failure.code == "bad_request"
      check handleArtifact(c, req("get_block", "dist/b.bin"), master, fixedStoreSet(be)).failure.code == "bad_request"
      # a put_end that names no digests is refused too
      let began2 = handleArtifact(c, b, master, fixedStoreSet(be))
      var nodig = req("put_end", "dist/a.bin"); nodig.upload_id = began2.upload_id; nodig.parts = @[artifactingest.ArtifactPart(part: 1, etag: "e1")]
      check handleArtifact(c, nodig, master, fixedStoreSet(be)).failure.code == "bad_request"
      gone.upload_id = began2.upload_id
      check handleArtifact(c, gone, master, fixedStoreSet(be)).accepted
      # an empty file is one request with no bytes
      var empty = req("put_object", "dist/empty.txt"); empty.size = 0; empty.sha256 = shaOf("")
      check handleArtifact(c, empty, master, fixedStoreSet(be)).accepted
      check c.storedArtifact(runId, "dist/empty.txt").found and objectKey(org, runId, "dist/empty.txt") notin be.objects      # the row says all there is; the store has no object of no bytes
      var notEmpty = req("put_object", "dist/x.txt"); notEmpty.size = 1; notEmpty.sha256 = shaOf("x")
      check handleArtifact(c, notEmpty, master, fixedStoreSet(be)).failure.code == "bad_request"

    test "D-61 put_end completes the upload when the digests of the shim are those of the module, and drops it when one is not":
      let be = Mem(objects: initTable[string, string]())
      let key = objectKey(org, runId, "dist/b.bin")
      var b = req("put_begin", "dist/b.bin")
      b.size = uint64(data.len)
      b.sha256 = shaOf(data)
      let began = handleArtifact(c, b, master, fixedStoreSet(be))
      check began.accepted
      be.objects[key] = data                                                                       # what the module would have after the complete
      var e = req("put_end", "dist/b.bin"); e.upload_id = began.upload_id
      let mine = @[artifactingest.ArtifactPart(part: 1, etag: "e1", sha256: shaOf(data[0 ..< 30])), artifactingest.ArtifactPart(part: 2, etag: "e2", sha256: shaOf(data[30 .. ^1]))]
      # the module received another second part
      be.received = @[(1, shaOf(data[0 ..< 30]), 30'i64), (2, shaOf("changed on the way"), 10'i64)]
      e.parts = mine
      let bad = handleArtifact(c, e, master, fixedStoreSet(be))
      check not bad.accepted and bad.failure.code == "digest_mismatch" and be.completed == 0 and be.aborted == 1
      check c.storedArtifact(runId, "dist/b.bin").found == false
      # a part missing at the module
      let again = handleArtifact(c, b, master, fixedStoreSet(be))
      e.upload_id = again.upload_id
      be.received = @[(1, shaOf(data[0 ..< 30]), 30'i64)]
      check handleArtifact(c, e, master, fixedStoreSet(be)).failure.code == "digest_mismatch"
      # digests for some parts only, or not hex
      let third = handleArtifact(c, b, master, fixedStoreSet(be))
      e.upload_id = third.upload_id
      e.parts = @[artifactingest.ArtifactPart(part: 1, etag: "e1", sha256: shaOf(data[0 ..< 30])), artifactingest.ArtifactPart(part: 2, etag: "e2")]
      check handleArtifact(c, e, master, fixedStoreSet(be)).failure.code == "bad_request"
      e.parts = @[artifactingest.ArtifactPart(part: 1, etag: "e1", sha256: "NOT-HEX"), artifactingest.ArtifactPart(part: 2, etag: "e2", sha256: shaOf("x"))]
      check handleArtifact(c, e, master, fixedStoreSet(be)).failure.code == "bad_request"
      # they agree
      e.parts = mine
      be.received = @[(1, shaOf(data[0 ..< 30]), 30'i64), (2, shaOf(data[30 .. ^1]), 10'i64)]
      let ok = handleArtifact(c, e, master, fixedStoreSet(be))
      check ok.accepted and be.completed == 1
      check c.storedArtifact(runId, "dist/b.bin").found

    test "D-61 a file that is stored is offered with a grant to read it, to a shim that can use one":
      let be = Mem(objects: initTable[string, string]())
      let key = objectKey(org, runId, "dist/b.bin")
      var l = req("get_list", "")
      l.names = @["dist"]
      let offered = handleArtifact(c, l, master, fixedStoreSet(be))
      check offered.accepted and offered.files.len == 2 and offered.direct_url == "http://module.test:18091"      # dist/b.bin and the file of no bytes of the first test
      let bin = offered.files.filterIt(it.path == "dist/b.bin")[0]
      check bin.direct_path == "/s/mem/" & key and verifyGrant(secret, "001", "mem", key, "", "r", bin.grant, now)
      check bin.sha256 == shaOf(data)
      let none = offered.files.filterIt(it.path == "dist/empty.txt")[0]
      check none.size == 0 and none.grant.len == 0
      l.direct = false
      let plain = handleArtifact(c, l, master, fixedStoreSet(be))
      check not plain.accepted and plain.failure.code == "direct_required"
    configureStorage("", "", "001")
