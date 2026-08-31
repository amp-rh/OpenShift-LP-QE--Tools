# BSOD Detector Toolkit — Architecture Overview (CGQE-801)

**One line:** An automatic crash investigator for Windows VMs — it **detects** a BSOD/freeze,
**captures** a screenshot + crash dumps, and **analyzes** the cause, saving everything as
structured JSON. ~5,000 lines. Author: hjoshi · 2026-08-25.

---

## 0. Email intro (copy-paste, 3 bullets)

> We've built and validated an automatic BSOD crash-investigator for Windows VMs (~5k lines):
>
> - **Detect → Capture → Analyze**: it detects a blue-screen or freeze, captures a screenshot and
>   the crash dumps, and produces a clear analysis of the cause — all saved as structured JSON reports.
> - **Proven end-to-end** on a test VM against two different crash types (all stages agreed on the
>   cause; one real bug found and fixed), and the host-side **TLB-flush signal tool is now adapted
>   for OpenShift**.
> - **Ask:** ready to trial in the **non-production sandbox on Vijay's TLB-flush setup**. Everything
>   needed to catch/capture/analyze is in place; the only open question is how the crash is triggered
>   there — that's the research goal, not a tooling gap.

---

## 1. The big picture

A crashing or frozen Windows VM often **can't report on itself**, so the toolkit is split
across two locations — some tools run *inside* the guest, some run *outside* on the host/node.
Both write into one shared evidence folder.

```
                    ┌──────────────────────────────────────────────┐
                    │   SHARED SOURCE-OF-TRUTH  (src/data/*.json)    │
                    │   bugcheck codes · trigger methods ·           │
                    │   crash-dump settings · host signals           │
                    └──────────────────────────────────────────────┘
                         ▲  every script reads its tables here (no hard-coding)
       ┌──────────────────┴───────────────────┐
       │                                       │
┌──────────────────────────┐      ┌────────────────────────────────────┐
│  INSIDE the Windows guest │      │  OUTSIDE — on the Linux host / node  │
│  (PowerShell)             │      │  (Bash)                              │
│                           │      │                                      │
│ • configure-dumps.ps1     │      │ • capture-vm-screen.sh   screenshot  │
│     set up dump writing   │      │ • collect-host-signals.sh  ← TLB-    │
│ • collect-guest.ps1       │      │     host-only split-lock/TLB signal  │
│     pull dumps + events   │      │ • collect-from-host.(sh|ps1)         │
│ • analyze-dump.ps1        │      │     detect freeze, recover dump      │
│     deep symbolized       │      │ • parse-dump-header.sh               │
│     analysis (MS debugger)│      │     read stop code, no debugger      │
│                           │      │ • host-tools/ (libguestfs)           │
│                           │      │     read dump off a disk image       │
└──────────────────────────┘      └────────────────────────────────────┘
       │                                       │
       └──────────────►  ONE EVIDENCE FOLDER  ◄─┘
             screenshot.png · *.dmp (dumps) · *.json (structured results)
```

**Design choices to highlight:**
- **One job per script**, each emits **exactly one JSON object** → automatable, consistent, no log-squinting.
- **All lookup tables live in `data/`** → adding a new crash code is a *data* change, not a code change.
- **Guest tools and host tools are separated** → host tools still work when the guest is dead or frozen.

---

## 2. What each stage delivers

| Stage | Tool | Output |
|-------|------|--------|
| BSOD / freeze **detection** | `collect-from-host.*` | is the guest crashed / hung / running? |
| **Screenshot** capture | `capture-vm-screen.sh` | `screenshot.png` of the blue screen + stop code |
| Crash **dump** collection | `collect-guest.ps1` / `host-tools/` | `MEMORY.DMP` + minidump |
| Dump **analysis** | `parse-dump-header.sh`, `analyze-dump.ps1` | stop code, guilty driver, call stack |
| Host-only **TLB-flush** signal | `collect-host-signals.sh` | split-lock `#AC` → HYPERVISOR_ERROR correlation |
| **Evidence manifest** | (assembled) | `evidence-summary.json` tying it all together |

---

## 3. Three questions people always ask

**Q: Where does it run?**
Both sides. Guest-side (PowerShell) *inside* Windows; host-side (Bash) *outside* — on the KVM
host, or on OpenShift via `oc debug node` / `oc exec` into the virt-launcher pod. The TLB-flush
tool is host-side because that signal **only exists on the host**, never in the guest dump.

**Q: Is the analysis post-mortem?**
**Mostly yes** — it investigates the evidence left behind *after* the crash (dumps, event log,
stop code). The two **live** parts are freeze/BSOD *detection* and the *screenshot*, which happen
at crash time.

**Q: Can we collect the dump WITHOUT restarting the VM?**
Three cases:
1. **Normal BSOD** — Windows itself reboots as it writes the dump (that reboot is *Windows'* behavior,
   not ours); we read the dump after it's back up.
2. **VM powered off (no Windows boot)** — Yes: `host-tools/` read `MEMORY.DMP` straight off the disk
   image offline. Good for an unbootable guest.
3. **Live, no restart** — Yes, for a *frozen/hung* guest: snapshot running memory via
   `virsh dump --memory-only` (or LiveKd). Caveat: that's a **raw QEMU/ELF image, not a native
   Windows dump** — needs different tooling (Volatility), used as a last resort.

> **Bottom line:** we can grab memory without a restart, but a *native Windows crash dump* is
> inherently tied to the BSOD-and-reboot that Windows performs itself.

---

## 4. Status & the ask

- **Validated end-to-end** on a test VM against **two different crash types** — every stage worked
  and all sources agreed on the cause. One real analysis bug was found and **fixed**.
- The **TLB-flush signal tool is now adapted for OpenShift** and tested with cluster-shaped inputs.
- **Ask:** ready to trial in the **non-production sandbox on Vijay's TLB-flush setup**. The only open
  question is *how the crash is triggered* there — that's the research goal, not a tooling gap.
  Everything needed to **catch, capture, and analyze** the crash is in place and tested.
