# CFV1 (MCF51JM128) debugging notes — from the TXR CW-RTOS bring-up (2026-07)

Field notes from an extended USBDM debugging campaign on a ColdFire V1 target
(MCF51JM128, USBDM-JMxx-CF pod HW=8C SW=4C, Raspberry Pi aarch64 host).

## UsbdmScript (TCL) — register commands EXIST
`rreg`, `wreg`, `regs`, `step`, `halt`, `go` are all registered in
`UsbdmTcl_DLL/src/UsbdmTclInterpreterImp.cpp` (~line 4460). We spent days
driving UsbdmGdbServer + a raw GDB-RSP client for register access that
UsbdmScript could have done directly. If you only need PC/SR/Dn/An at a halt:
`halt; regs; go` in a TCL script is enough.

## CFV1 halt quirks observed
- **D0/D1 read as constants after halt** (`0xCF100029` / `0x10901060` — the
  CFV1 core ID/reset patterns) regardless of actual task state; D2-D7/An/PC/SR
  read correctly. Treat D0/D1 from a halted CFV1 as unreliable.
- GDB server occasionally emits a spurious `T02` stop reply on connect/poll.
- Memory reads via BDM while the target is in STOP return all-0xFF — a target
  sleeping in STOP looks identical to a dead link. Distinguish with RAM
  heartbeat counters sampled over time.
- `reset s s` + reads = post-mortem of the PREVIOUS run's persistent RAM only;
  it restarts the chip (volatile evidence is destroyed).

## Link stability (the big one)
The pod link on this host needed a USB hub power-cycle (`uhubctl`) before most
sessions (SYNC timeouts, ACK-missing, dead reads). Mitigations:
- udev: pods (16d0:*) now get `power/control=on` (autosuspend off) —
  see PackageFiles/MiscellaneousLinux/usbdm.rules.
- Operational order matters: power-cycle the TARGET first, then recycle the
  pod, then connect; verify the link with a known flash byte before trusting
  reads; retry loops around every session.
- Suspected but unproven: glitchy connects can disturb the target RESET line.
  A resident daemon holding one BDM session (instead of per-script
  open/close) would shrink the glitch surface — TODO.

## TODO (code-level)
- GdbHandler: investigate/annotate the CFV1 D0/D1 halt clobber; suppress
  spurious T02.
- UsbdmScript: a `connect`-without-reset assertion mode documented for
  non-intrusive attach.
