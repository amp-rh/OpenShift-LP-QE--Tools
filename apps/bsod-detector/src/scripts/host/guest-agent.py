#!/usr/bin/env python3
"""guest-agent.py -- drive a KubeVirt Windows guest via the qemu-guest-agent.

WHY
    On a KubeVirt/OpenShift cluster there is no passt SSH to the VM. The guest is
    reachable through the qemu-guest-agent, which is spoken by `virsh` inside the
    VM's virt-launcher pod. This wraps that RPC so the BSOD pipeline (stage toolkit,
    trigger a crash, collect dumps, pull evidence) can run with no SSH and no
    credentials -- guest-exec runs as `nt authority\\system` (fully elevated).

HOW IT REACHES THE GUEST
    oc exec -n <ns> <virt-launcher-pod> -- \\
        virsh qemu-agent-command <domain> '<qmp-json>'
    where <domain> is "<namespace>_<vmname>" (e.g. windows-bsod_hjoshi-win2022).

SUBCOMMANDS
    ping                          guest-ping (liveness)
    exec  <program> [args...]     run a command, wait, print stdout/stderr/exit
    psfile <local.ps1> [args...]  upload a local .ps1 and run it (powershell -File)
    put   <local> <guestpath>     upload a local file to the guest
    get   <guestpath> <local>     download a guest file (seek-based, retriable)

TRANSFER NOTES (learned the hard way)
    - guest-file-read count is capped by the QMP payload limit: 2MB works, 4MB
      returns "Unable to encode message payload". Default read chunk here is 1MB.
    - A truncated oc-exec/QMP response would otherwise desync the file position, so
      get() seeks to an explicit offset before every read and retries the chunk.
    - For a large MEMORY.DMP, compress in-guest first (see compress-dump.ps1);
      kernel dumps shrink to ~14% and the transfer runs at ~0.5 MB/s.

CONFIG (all optional -- the target is auto-resolved from the cluster)
    GA_VM   VM (VirtualMachineInstance) name. If unset, and exactly one VMI is
            found (in GA_NS if set, else cluster-wide), it is used automatically.
    GA_NS   namespace. If unset, taken from the auto-detected VMI (or from GA_DOM).
    GA_DOM  libvirt domain name. Defaults to "<GA_NS>_<GA_VM>".
    GA_POD  virt-launcher pod. Defaults to the running virt-launcher-<vm>-* pod
            resolved from the cluster (no more stale hardcoded pod suffixes).
    Nothing is hardcoded to a particular VM: with a single VMI you can run with no
    env vars at all; otherwise set GA_VM (and GA_NS if it is ambiguous).
"""
import base64, json, os, subprocess, sys, time

NS  = os.environ.get("GA_NS")
VM  = os.environ.get("GA_VM")
POD = os.environ.get("GA_POD")
DOM = os.environ.get("GA_DOM")

_resolved = False


def _oc(args):
    """Run `oc <args>` and return stripped stdout, or '' on failure."""
    r = subprocess.run(["oc"] + args, capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else ""


def _resolve_pod(ns, vm):
    for line in _oc(["get", "pod", "-n", ns, "-o", "name"]).splitlines():
        name = line.split("/", 1)[-1]
        if name.startswith("virt-launcher-{}-".format(vm)):
            return name
    return ""


def resolve_target():
    """Fill in NS/VM/DOM/POD from the cluster so nothing has to be hardcoded.
    Explicit env vars always win; only the missing pieces are looked up."""
    global NS, VM, POD, DOM, _resolved
    if _resolved:
        return
    # A domain name is "<ns>_<vm>" (k8s names never contain '_') -> back it out.
    if DOM and (not NS or not VM) and "_" in DOM:
        n, v = DOM.split("_", 1)
        NS = NS or n
        VM = VM or v
    # Auto-detect the VM when not told: unambiguous only if exactly one VMI exists.
    if not VM:
        jp = '{range .items[*]}{.metadata.namespace} {.metadata.name}{"\\n"}{end}'
        scope = ["-n", NS] if NS else ["-A"]
        rows = [r for r in _oc(["get", "vmi"] + scope + ["-o", "jsonpath=" + jp]).splitlines() if r.strip()]
        if len(rows) == 1:
            n, v = rows[0].split()[:2]
            NS = NS or n
            VM = v
        elif not rows:
            sys.exit("guest-agent: no VirtualMachineInstance found; set GA_VM (and GA_NS)")
        else:
            sys.exit("guest-agent: multiple VMs found -- set GA_VM (and GA_NS):\n  " + "\n  ".join(rows))
    if not NS:
        sys.exit("guest-agent: namespace unknown; set GA_NS (or GA_DOM=<ns>_<vm>)")
    if not DOM:
        DOM = "{}_{}".format(NS, VM)
    if not POD:
        POD = _resolve_pod(NS, VM)
        if not POD:
            sys.exit("guest-agent: no running virt-launcher pod for VM '{}' in ns '{}'".format(VM, NS))
    _resolved = True


def agent(cmd_obj, timeout=60):
    """Send one qemu-agent-command and return its 'return' payload."""
    resolve_target()
    payload = json.dumps(cmd_obj)
    out = subprocess.run(
        ["oc", "exec", "-n", NS, POD, "--",
         "virsh", "qemu-agent-command", "--timeout", str(timeout), DOM, payload],
        capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError(f"virsh failed: {out.stderr.strip() or out.stdout.strip()}")
    return json.loads(out.stdout)["return"]


def guest_exec(path, args=None, wait=True, poll_timeout=180):
    """Run a program in the guest. wait=False returns immediately (use when the
    command is expected to crash the guest, e.g. a BSOD trigger)."""
    r = agent({"execute": "guest-exec", "arguments": {
        "path": path, "arg": args or [], "capture-output": True}})
    pid = r["pid"]
    if not wait:
        return {"pid": pid}
    deadline = time.time() + poll_timeout
    while time.time() < deadline:
        st = agent({"execute": "guest-exec-status", "arguments": {"pid": pid}})
        if st.get("exited"):
            out = base64.b64decode(st["out-data"]).decode("utf-8", "replace") if st.get("out-data") else ""
            err = base64.b64decode(st["err-data"]).decode("utf-8", "replace") if st.get("err-data") else ""
            return {"pid": pid, "exitcode": st.get("exitcode"), "stdout": out, "stderr": err}
        time.sleep(2)
    return {"pid": pid, "timeout": True}


def guest_put(local, guestpath):
    """Upload a local file to the guest via guest-file-write (256KB base64 chunks)."""
    data = open(local, "rb").read()
    handle = agent({"execute": "guest-file-open",
                    "arguments": {"path": guestpath, "mode": "wb"}})
    try:
        CH = 256 * 1024
        for i in range(0, len(data), CH):
            chunk = base64.b64encode(data[i:i + CH]).decode()
            agent({"execute": "guest-file-write",
                   "arguments": {"handle": handle, "buf-b64": chunk}})
    finally:
        agent({"execute": "guest-file-close", "arguments": {"handle": handle}})
    return len(data)


def guest_get(guestpath, local, chunk=1024 * 1024):
    """Download a guest file. Seek-based + per-chunk retries so a truncated
    response can be re-read without desyncing the file position."""
    handle = agent({"execute": "guest-file-open", "arguments": {"path": guestpath, "mode": "rb"}})
    total = 0
    try:
        offset = 0
        while True:
            last = None
            for _ in range(5):
                try:
                    agent({"execute": "guest-file-seek",
                           "arguments": {"handle": handle, "offset": offset, "whence": 0}})
                    r = agent({"execute": "guest-file-read",
                               "arguments": {"handle": handle, "count": chunk}})
                    break
                except Exception as e:
                    last = e; time.sleep(1.5)
            else:
                raise RuntimeError(f"chunk at offset {offset} failed after retries: {last}")
            b = base64.b64decode(r["buf-b64"]) if r.get("buf-b64") else b""
            if b:
                with open(local, "r+b" if offset else "wb") as f:
                    f.seek(offset); f.write(b)
                offset += len(b); total = offset
            if r.get("eof") or not b:
                break
    finally:
        agent({"execute": "guest-file-close", "arguments": {"handle": handle}})
    return total


def main():
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(2)
    cmd = sys.argv[1]
    if cmd == "ping":
        print(agent({"execute": "guest-ping"}, timeout=10)); return
    if cmd == "exec":
        r = guest_exec(sys.argv[2], sys.argv[3:])
        print(f"[exit {r.get('exitcode')}]")
        if r.get("stdout"): sys.stdout.write(r["stdout"] + ("" if r["stdout"].endswith("\n") else "\n"))
        if r.get("stderr"): sys.stderr.write("STDERR:\n" + r["stderr"] + "\n")
        return
    if cmd == "put":
        n = guest_put(sys.argv[2], sys.argv[3]); print(f"wrote {n} bytes -> {sys.argv[3]}"); return
    if cmd == "get":
        n = guest_get(sys.argv[2], sys.argv[3]); print(f"read {n} bytes -> {sys.argv[3]}"); return
    if cmd == "psfile":
        local = sys.argv[2]
        guestpath = "C:\\Windows\\Temp\\" + local.replace("\\", "/").split("/")[-1]
        n = guest_put(local, guestpath); print(f"[uploaded {n}B -> {guestpath}]")
        r = guest_exec("powershell.exe",
                       ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", guestpath] + sys.argv[3:])
        print(f"[exit {r.get('exitcode')}]")
        if r.get("stdout"): sys.stdout.write(r["stdout"])
        if r.get("stderr"): sys.stderr.write("STDERR:\n" + r["stderr"])
        return
    print("unknown cmd", cmd); sys.exit(2)


if __name__ == "__main__":
    main()
