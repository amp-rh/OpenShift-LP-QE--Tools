# Guest-Side Scripts

PowerShell scripts that run **inside the Windows guest VM**.

In the offline-first architecture, the guest is a **pure crash target** — evidence
is extracted from the guest disk after the VM is stopped, not collected by
scripts running inside the guest. These remaining guest-side scripts handle
one-time configuration only.

## Scripts

| Script | Description |
|---|---|
| `configure-dumps.ps1` | Configure Windows CrashControl registry settings (dump type, `AutoReboot=0`, page file adequacy). One-time guest setup. |
| `clear-dumps.ps1` | Delete existing crash dumps before a test so evidence contains only the new crash. |

## Crash injection scripts

Guest-side crash injection scripts (trigger-bsod.ps1, install.ps1, etc.) live
under [`../crash-injector/`](../crash-injector/README.md) — they are test-only
and quarantined from the detection/collection pipeline.
