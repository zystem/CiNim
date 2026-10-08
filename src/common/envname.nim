## The names that may be environment variables of a step (STO-004, SEC-011, VAR-003): the same rule for the env files that the shim parses and
## for the secrets that the core stores, so that a secret can never be named what a file may not set (`PATH`, `LD_PRELOAD`, `CICD_*`...).
import std/strutils

const
  deniedNames = ["PATH", "IFS", "BASH_ENV", "ENV", "SHELL", "HOME", "NODE_OPTIONS", "NODE_PATH", "PYTHONPATH",
                 "PYTHONHOME", "PYTHONSTARTUP", "RUBYOPT", "RUBYLIB", "PERL5OPT", "PERL5LIB", "JAVA_TOOL_OPTIONS",
                 "_JAVA_OPTIONS", "JDK_JAVA_OPTIONS", "GCONV_PATH", "HOSTALIASES", "LOCPATH", "NLSPATH",
                 "PS4", "PROMPT_COMMAND", "CDPATH", "GLOBIGNORE", "SHELLOPTS", "BASHOPTS"]
  deniedPrefixes = ["LD_", "CICD_", "BASH_FUNC_", "DYLD_", "GLIBC_"]

func validEnvName*(name: string; maxLen = 256): bool =
  if name.len == 0 or name.len > maxLen: return false
  if name[0] notin {'A'..'Z', '_'}: return false
  for c in name:
    if c notin {'A'..'Z', '0'..'9', '_'}: return false
  true

func deniedEnvName*(name: string): bool =
  if name in deniedNames: return true
  for p in deniedPrefixes:
    if name.startsWith(p): return true

func stepSecretObjectName*(name: string; version: int): string =
  ## the Kubernetes Secret that holds one version of an organisation's step secret: `cinim-s-registry-password-v3` for REGISTRY_PASSWORD. A new value is a
  ## new version (the core may create and delete Secrets, not change them), and the step is told which version to use.
  "cinim-s-" & name.toLowerAscii.replace('_', '-') & "-v" & $version
