# VS Code Extension for USBDM -- Assessment

A dedicated VS Code extension for USBDM would provide device selection
(dropdown of supported MCUs), one-click flash programming, automatic GDB server
lifecycle management (start before debug, kill after), and Xvfb handling
transparent to the user. It could also surface USBDM connection status in the
status bar.

**Complexity is moderate.** The Cortex-Debug extension (the closest comparison)
is roughly 15k lines of TypeScript and implements a full debug adapter. That
level of effort is unnecessary here. The USBDM GDB server already speaks
standard GDB remote protocol, so VS Code's built-in `cppdbg` debug type works
fine. The extension would not need a custom debug adapter -- it would provide
task definitions, a configuration provider for launch.json, and commands for
flash/erase. Estimated effort: 1-2 weeks for an MVP, versus months for
something like Cortex-Debug.

**It should be a separate repository**, not part of the USBDM source tree. VS
Code extensions have their own build tooling (webpack/esbuild, vsce packaging)
that does not belong in an embedded C++ project.

**Recommended approach:** Start with a thin wrapper extension that contributes
(1) a "USBDM: Start GDB Server" command that manages Xvfb + USB reset +
server launch, (2) a "USBDM: Flash" command that invokes UsbdmFlashProgrammer,
and (3) a configuration snippet provider for launch.json. Use the existing
`cppdbg` debug type -- do not reimplement the debug adapter protocol. This
keeps the extension small and maintainable while eliminating the need for users
to manually create `start_gdbserver.sh` scripts.
