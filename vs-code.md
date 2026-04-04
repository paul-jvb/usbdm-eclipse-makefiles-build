# VS Code Debugging with USBDM

## Overview

This guide covers setting up VS Code for embedded debugging of ColdFire V1
(MCF51JM128) targets using the USBDM GDB server. The setup works over SSH
(VS Code Remote) on a Raspberry Pi 5 running Debian Trixie.

The toolchain:
- **VS Code** with the C/C++ extension connects to a GDB instance
- **gdb-multiarch** speaks the GDB remote protocol to the USBDM GDB server
- **UsbdmGdbServer** communicates with the USBDM BDM pod over USB
- **Xvfb** provides a virtual display so the wxWidgets-based server can run
  headlessly

## Prerequisites

| Component | Package / Source |
|-----------|-----------------|
| VS Code | `code` (or VS Code Remote via SSH) |
| C/C++ extension | `ms-vscode.cpptools` (install from Extensions panel) |
| GDB | `gdb-multiarch` (apt) or `m68k-elf-gdb` (build from source) |
| Virtual display | `xvfb`, `xdotool` (apt) |
| Cross compiler | `gcc-13-m68k-linux-gnu`, `binutils-m68k-linux-gnu` (apt, for IntelliSense) |
| USBDM GDB Server | Patched `UsbdmGdbServer` binary in `/usr/bin/` (see `arm.md`) |

Install the apt packages:

```bash
sudo apt install -y xvfb xdotool gdb-multiarch \
    gcc-13-m68k-linux-gnu binutils-m68k-linux-gnu
```

## Project Setup

Create a `.vscode/` directory in your project with the following files.

### launch.json

```json
{
    "version": "0.2.0",
    "configurations": [
        {
            "name": "Debug (USBDM)",
            "type": "cppdbg",
            "request": "launch",
            "program": "${workspaceFolder}/build/firmware.elf",
            "cwd": "${workspaceFolder}",
            "MIMode": "gdb",
            "miDebuggerPath": "/usr/bin/gdb-multiarch",
            "miDebuggerServerAddress": "localhost:1234",
            "stopAtEntry": true,
            "setupCommands": [
                { "text": "set remotetimeout 10" },
                { "text": "set mem inaccessible-by-default off" }
            ],
            "preLaunchTask": "Start GDB Server",
            "logging": {
                "engineLogging": false,
                "moduleLoad": false
            }
        }
    ]
}
```

Key settings:
- `stopAtEntry: true` -- halts at the entry point so you can orient yourself
- `set remotetimeout 10` -- gives the slow BDM link time to respond
- `set mem inaccessible-by-default off` -- allows reading peripheral registers
- `preLaunchTask` -- automatically starts the GDB server before connecting
- **Do not** add a separate `preLaunchTask` for building if it causes the
  debug session to fail to attach. Keep the launch config simple.

### tasks.json

```json
{
    "version": "2.0.0",
    "tasks": [
        {
            "label": "Build",
            "type": "shell",
            "command": "make",
            "group": { "kind": "build", "isDefault": true },
            "problemMatcher": "$gcc"
        },
        {
            "label": "Clean",
            "type": "shell",
            "command": "make clean",
            "problemMatcher": []
        },
        {
            "label": "Flash",
            "type": "shell",
            "command": "make flash",
            "dependsOn": "Build",
            "problemMatcher": []
        },
        {
            "label": "Start GDB Server",
            "type": "shell",
            "command": "${workspaceFolder}/start_gdbserver.sh",
            "problemMatcher": [],
            "presentation": { "reveal": "always", "panel": "dedicated" }
        }
    ]
}
```

### c_cpp_properties.json

```json
{
    "configurations": [
        {
            "name": "MCF51JM128 (GCC m68k)",
            "compilerPath": "/usr/bin/m68k-linux-gnu-gcc-13",
            "compilerArgs": ["-mcpu=51jm", "-ffreestanding"],
            "intelliSenseMode": "linux-gcc-x64",
            "includePath": ["${workspaceFolder}"],
            "cStandard": "c99"
        }
    ],
    "version": 4
}
```

Note: `intelliSenseMode` is set to `linux-gcc-x64` because IntelliSense does
not support the m68k/ColdFire architecture. This is close enough for header
parsing.

### settings.json

```json
{
    "C_Cpp.intelliSenseEngine": "Tag Parser",
    "C_Cpp.errorSquiggles": "disabled"
}
```

The **Tag Parser** engine is used instead of the full IntelliSense engine
because the latter does not support the m68k target architecture. Error
squiggles are disabled to avoid false positives from cross-compilation
keywords.

### intellisense_compat.h (optional)

If your project uses CodeWarrior-specific keywords (`__declspec`, `__interrupt`,
`asm`), create a compatibility header and force-include it via
`c_cpp_properties.json`:

```c
#ifdef __INTELLISENSE__

#ifdef __declspec
#undef __declspec
#endif
#define __declspec(x)

#ifdef asm
#undef asm
#endif
#define asm

#define __interrupt

#endif /* __INTELLISENSE__ */
```

Add to `c_cpp_properties.json`:

```json
"forcedInclude": ["${workspaceFolder}/.vscode/intellisense_compat.h"]
```

This suppresses IntelliSense errors from keywords it cannot parse. The
`__INTELLISENSE__` guard ensures it only affects the VS Code parser, not actual
compilation.

### start_gdbserver.sh

Place this script in the project root and make it executable
(`chmod +x start_gdbserver.sh`):

```bash
#!/bin/bash
# Start USBDM GDB server for VS Code debugging
pkill -f UsbdmGdbServer 2>/dev/null
pkill -f 'Xvfb :88' 2>/dev/null
sleep 1

# Reset USB device if needed (vendor 16d0 = USBDM)
USBDEV=$(ls /sys/bus/usb/devices/ 2>/dev/null | while read d; do
    [ -f "/sys/bus/usb/devices/$d/idVendor" ] && \
    grep -q 16d0 "/sys/bus/usb/devices/$d/idVendor" 2>/dev/null && echo "$d"
done)
if [ -n "$USBDEV" ]; then
    sudo sh -c "echo '$USBDEV' > /sys/bus/usb/drivers/usb/unbind" 2>/dev/null
    sleep 1
    sudo sh -c "echo '$USBDEV' > /sys/bus/usb/drivers/usb/bind" 2>/dev/null
    sleep 2
    sudo chmod 666 /dev/bus/usb/003/* 2>/dev/null
fi

rm -f /tmp/.X88-lock /tmp/.X11-unix/X88 2>/dev/null
setsid Xvfb :88 -screen 0 640x480x8 -ac &>/dev/null &
sleep 1

setsid env DISPLAY=:88 UsbdmGdbServer -target=cfv1 -device=MCF51JM128 -port=1234 &>/dev/null &

for i in $(seq 1 30); do
    if ss -tln 2>/dev/null | grep -q ':1234'; then
        echo "GDB server ready on port 1234"
        exit 0
    fi
    sleep 0.5
done

echo "ERROR: GDB server failed to start"
exit 1
```

Adjust `-device=` and `-target=` for your specific MCU. Do **not** add
`-vdd=3V3` if your target board has its own power supply.

## Workflow

1. **Build**: Press `Ctrl+Shift+B` (runs the default Build task via `make`)
2. **Flash**: Run Terminal > Run Task > "Flash" (builds first, then programs
   the target via `make flash`)
3. **Debug**: Press `F5`. This automatically:
   - Runs `start_gdbserver.sh` (kills old instances, resets USB, starts Xvfb,
     launches UsbdmGdbServer on port 1234)
   - Launches gdb-multiarch connecting to `localhost:1234`
   - Loads the ELF symbols and halts at the entry point
4. **Stepping**: `F10` = step over, `F11` = step into, `Shift+F11` = step out
5. **Breakpoints**: Click the gutter (left margin) next to a line number
6. **Stop**: `Shift+F5` or the red square button in the debug toolbar

## Known Issues

### IntelliSense Does Not Support m68k

The full IntelliSense engine (`Default`) does not understand the m68k/ColdFire
architecture. Symptoms include spurious errors on valid code and missing symbol
resolution. Solution: use `"C_Cpp.intelliSenseEngine": "Tag Parser"` in
`settings.json`. The Tag Parser is less precise but handles cross-compilation
projects better.

### `__declspec` Keyword

IntelliSense treats `__declspec` as a built-in keyword and will not allow it to
be redefined via `#define`. CodeWarrior projects use `__declspec(section_name)`
for memory placement. The workaround is the `intellisense_compat.h` forced
include described above, or simply disabling error squiggles.

### Patched UsbdmGdbServer Required for GDB 16.3+

GDB 16.3 sends compound `vCont` commands (e.g. `vCont;c:-1;s:1`). The upstream
USBDM GDB server misparses these, causing single-step (`F10`/`F11`) to behave
like continue. The patched binary with the compound vCont parser must be
installed. See `arm.md` for details.

### USB Reset Between Flash and Debug

The USBDM BDM pod can get into a bad state after a flash operation. The
`start_gdbserver.sh` script handles this by unbinding and rebinding the USB
device before starting the GDB server.

### External Target Power

Do not pass `-vdd=3V3` to UsbdmGdbServer when the target has its own power
supply. This flag enables VDD output from the BDM pod and can cause contention.
