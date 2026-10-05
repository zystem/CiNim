#!/usr/bin/env python3
"""Makes the seccomp profile `cinim-userns` (A.13, Q-17) from Docker's default profile (moby/profiles, seccomp/default.json):

  the default profile as an unprivileged container with the capabilities of the build profile gets it (the entries that need
  CAP_SYS_ADMIN and the like are left out, as the runtime does), converted to the OCI format that Kubernetes' `Localhost` profiles use,
  plus the calls that a rootless builder needs to make its own user and mount namespaces and to start a nested container (the EXTRA list
  below, found by running the build). Everything else that the default profile forbids stays forbidden: bpf, perf_event_open, quotactl,
  syslog, fanotify_init, lookup_dcookie and the kernel-module, reboot, time and raw-I/O calls.

  tools/build-test/seccomp-userns.py default.json > deploy/seccomp/cinim-userns.json
"""
import json, sys

GRANTED = {"CAP_CHOWN", "CAP_DAC_OVERRIDE", "CAP_FOWNER", "CAP_SETUID", "CAP_SETGID", "CAP_SETFCAP"}   # the build profile's capabilities
ARCHES = {"amd64", "arm64"}                                                    # what Talos nodes are
EXTRA = ["unshare", "setns", "mount", "umount", "umount2", "pivot_root", "chroot",       # namespaces and the root of the nested container
         "sethostname", "setdomainname",                                                 # runc sets the hostname of the nested container
         "fsopen", "fsconfig", "fsmount", "fspick", "move_mount", "open_tree", "mount_setattr",   # the new mount API
         "keyctl"]                                                                       # runc joins a session keyring; plus `clone` without a flag filter
OCI_ARCH = {"SCMP_ARCH_X86_64": ["SCMP_ARCH_X86_64", "SCMP_ARCH_X86", "SCMP_ARCH_X32"], "SCMP_ARCH_AARCH64": ["SCMP_ARCH_AARCH64", "SCMP_ARCH_ARM"]}

def applies(e):
    inc, exc = e.get("includes", {}), e.get("excludes", {})
    if inc.get("caps") and not (set(inc["caps"]) & GRANTED): return False
    if inc.get("arches") and not (set(inc["arches"]) & ARCHES): return False
    if exc.get("caps") and (set(exc["caps"]) & GRANTED): return False
    if exc.get("arches") and ARCHES <= set(exc["arches"]): return False
    return True

d = json.load(open(sys.argv[1]))
out = {"defaultAction": d["defaultAction"], "defaultErrnoRet": d.get("defaultErrnoRet", 1),
       "architectures": [a for k in OCI_ARCH for a in OCI_ARCH[k]], "syscalls": []}
for e in d["syscalls"]:
    if not applies(e): continue
    if e["names"] == ["clone"]: continue      # the entry that filters the namespace flags: replaced by the unconditional allow below
    s = {"names": e["names"], "action": e["action"]}
    if "errnoRet" in e: s["errnoRet"] = e["errnoRet"]
    if "args" in e: s["args"] = e["args"]
    out["syscalls"].append(s)
out["syscalls"].append({"names": ["clone"] + EXTRA, "action": "SCMP_ACT_ALLOW"})
json.dump(out, sys.stdout, indent=2); print()
