---@meta cicd
-- Lua API v1 of pipeline scripts (spec 6.7, PIP-017). LuaLS annotations: signatures are normative and fixed for the whole of v1.
-- `local ci = require("cicd")`. "journaled" calls are recorded in the run journal and replayed (PIP-003).
-- Values of secrets never enter Lua: scripts only hold opaque handles (SecretHandle).

---@alias Duration string|number           # "90s", "15m", "2h" or seconds
---@alias LogLevel "debug"|"info"|"warn"|"error"

---@class Param                            # a typed parameter declaration (PIP-012), built by ci.string, ci.number, ...
---@class SecretHandle                     # opaque reference to a secret (ci.secret param value, ci.vault)
---@class StepResult
---@field code integer                     # exit code of the step
---@field outputs table<string,string>     # values from $CICD_OUTPUT (STO-003), replayed from the journal
---@field stdout? string                   # only when requested with opts.capture
---@class JobResult
---@field ok boolean
---@field outputs table<string,string>
---@class InputResult
---@field approved boolean
---@field approver string
---@field comment string
---@class RunResult
---@field run_id string
---@field state string                     # terminal run state (states.nim)
---@field outputs table<string,string>
---@class Run                              # argument of main
---@field params table<string,any>
---@field ref string
---@field sha string
---@field changed_paths fun(): string[]    # journaled (PRJ-004)

---@class ConcurrencySpec
---@field group string
---@field policy "queue"|"cancel-oldest"|"cancel-newest"

---@class PipelineSpec
---@field name string
---@field on? table<string,any>
---@field params? table<string,Param>
---@field env? table<string,string>
---@field requires? string[]               # execution profiles
---@field storage? {size:string}
---@field permissions? string[]
---@field concurrency? ConcurrencySpec
---@field timeout? Duration
---@field main fun(run: Run)

---@class JobOpts
---@field image string
---@field profile? string
---@field resources? {cpu?:string, memory?:string}
---@field timeout? Duration
---@field retry? integer|{max:integer, backoff?:Duration}
---@field services? table<string,{image:string, env?:table<string,string>}>
---@field permissions? string[]
---@field env? table<string,string>
---@field secrets? table<string,SecretHandle>
---@field workspace? "shared"|"isolated"   # default "shared" (STO-002)

---@class ShOpts
---@field image? string
---@field env? table<string,string>
---@field timeout? Duration
---@field capture? boolean
---@field ignore_failure? boolean          # a non-zero code is returned instead of failing the job

---@class ParallelOpts
---@field fail_fast? boolean

---@class MatrixSpec
---@field axes table<string,any[]>
---@field include? table[]
---@field exclude? table[]
---@field max_parallel? integer
---@field fail_fast? boolean

---@class InputSpec
---@field message string
---@field approvers? string[]
---@field timeout? Duration
---@field params? table<string,Param>

---@class RunOpts
---@field wait? boolean                    # default true
---@field project? string

local ci = {}

-- metadata phase: pure functions, no side effects, not journaled (PIP-002) ------------------------------------------
---@param spec PipelineSpec
---@return PipelineSpec
function ci.pipeline(spec) end
---@param opts? {default?:string, description?:string, pattern?:string}
---@return Param
function ci.string(opts) end
---@param opts? {default?:number, description?:string, min?:number, max?:number}
---@return Param
function ci.number(opts) end
---@param opts? {default?:boolean, description?:string}
---@return Param
function ci.bool(opts) end
---@param values string[]
---@param opts? {default?:string, description?:string}
---@return Param
function ci.choice(values, opts) end
---@param element Param
---@param opts? {default?:any[], description?:string, max_items?:integer}
---@return Param
function ci.list(element, opts) end
---@param element Param
---@param opts? {default?:table, description?:string}
---@return Param
function ci.map(element, opts) end
---@param opts? {description?:string}
---@return Param
function ci.secret(opts) end
---@param path string
---@return SecretHandle
function ci.vault(path) end
---@param spec MatrixSpec
---@return table[]                         # not journaled; the expansion limit is checked at the call (PIP-009)
function ci.matrix(spec) end

-- main: journaled calls (PIP-003) ----------------------------------------------------------------------------------
---@param name string
---@param fn fun()
function ci.stage(name, fn) end
---@param opts JobOpts
---@param fn fun(j: Job)
---@return JobResult
function ci.job(opts, fn) end
---@param env string
---@param fn fun(j: Job)
---@return JobResult
function ci.deploy(env, fn) end
---@param branches table<string,fun()>
---@param opts? ParallelOpts
---@return table<string,any>               # results by branch name
function ci.parallel(branches, opts) end
---@param fn fun()
---@return Handle
function ci.spawn(fn) end
---@param spec InputSpec
---@return InputResult
function ci.input(spec) end
---@param ref string                       # project/pipeline reference; the same shard only (SHD-002)
---@param params? table<string,any>
---@param opts? RunOpts
---@return RunResult
function ci.run(ref, params, opts) end
---@param fn fun()
function ci.finally(fn) end
---@param seconds number
function ci.sleep(seconds) end
---@return number                          # Unix time in seconds (fractional), from the journal on replay
function ci.now() end
---@return number                          # in [0, 1), from the journal on replay
function ci.random() end

-- everywhere --------------------------------------------------------------------------------------------------------
---@param level LogLevel
---@param msg string
function ci.log(level, msg) end
---@param msg string
---@return nil                             # never returns: fails the run with the message
function ci.fail(msg) end

---@class Handle
local Handle = {}
---@return any
function Handle:wait() end
function Handle:cancel() end

---@class JobArtifact
local JobArtifact = {}
---@param path string
---@param opts? {name?:string, retention?:Duration}
---@return {name:string, sha256:string}
function JobArtifact.upload(path, opts) end
---@param name string
---@param opts? {to?:string}
---@return {path:string, sha256:string}
function JobArtifact.download(name, opts) end

---@class JobCache
local JobCache = {}
---@param key string
---@param paths string[]
function JobCache.save(key, paths) end
---@param keys string[]                    # tried in order; the first hit wins
---@return {hit:boolean, key?:string}
function JobCache.restore(keys) end

---@class Job                              # argument of the job function
---@field artifact JobArtifact
---@field cache JobCache
local Job = {}
---@param opts? {url?:string, ref?:string, depth?:integer, submodules?:boolean, lfs?:boolean}
---@return StepResult
function Job:checkout(opts) end
---@param cmd string
---@param opts? ShOpts
---@return StepResult
function Job:sh(cmd, opts) end
---@param ref string                       # plugin reference pinned by digest or SemVer from the lockfile
---@param inputs? table<string,any>        # validated against the plugin JSON Schema
---@return StepResult
function Job:use(ref, inputs) end
---@param tbl table<string,string>         # environment for the following steps of the job; no Pod is started
function Job:env(tbl) end

return ci
