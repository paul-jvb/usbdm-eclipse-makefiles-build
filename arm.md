# USBDM ARM64 (aarch64) Port

## Overview

USBDM (Universal BDM) was originally built for x86 Linux and Windows. This
document covers porting the GDB server component to ARM64, specifically the
Raspberry Pi 5 running Debian Trixie (64-bit).

The build system in `Common.mk` auto-detects the platform via `uname -m` and
`gcc --print-multiarch`. On an aarch64 system these resolve to:

- `UNAME_M = aarch64`
- `MULTIARCH = aarch64-linux-gnu`
- `BITNESS = 64`

No source-level `#ifdef` changes are needed for the GDB server -- the platform
differences are handled entirely by the Makefile variables.

USBDM version: **4.12.1** (as defined in `Common.mk`).

## Prerequisites

Install the following packages on Debian Trixie / Raspberry Pi OS (64-bit):

```bash
sudo apt install -y \
    build-essential gcc g++ \
    libwxgtk3.2-dev \
    libusb-1.0-0-dev \
    libxerces-c-dev \
    xvfb xdotool
```

- `libwxgtk3.2-dev` -- wxWidgets 3.2 (the build uses `wx-config --cppflags`
  and `wx-config --libs` to discover paths)
- `libusb-1.0-0-dev` -- USB access (linked as `-lusb-1.0`)
- `libxerces-c-dev` -- XML parsing (linked as `-lxerces-c`)
- `xvfb`, `xdotool` -- virtual framebuffer for headless operation (see below)

## Building the GDB Server

```bash
cd ~/USBDM/GdbServer
make -f Makefile-x64.mk UsbdmGdbServer
```

`Makefile-x64.mk` invokes `Target.mk` with `BITNESS=64`. On Linux the
`MULTIARCH` variable is set to whatever `gcc --print-multiarch` returns
(e.g. `aarch64-linux-gnu`), so the build directory suffix and output paths
adjust automatically.

The stripped binary is placed at:

```
PackageFiles/bin/aarch64-linux-gnu/UsbdmGdbServer
```

Shared libraries are built separately and placed under
`PackageFiles/lib/aarch64-linux-gnu/`. The GDB server finds them at runtime
via an rpath set to `/usr/lib/aarch64-linux-gnu/usbdm`.

To build the debug variant:

```bash
make -f Makefile-x64.mk UsbdmGdbServer-debug
```

## Installation

Copy the binary and shared libraries:

```bash
sudo cp PackageFiles/bin/aarch64-linux-gnu/UsbdmGdbServer /usr/bin/
sudo cp PackageFiles/lib/aarch64-linux-gnu/*.so* /usr/lib/aarch64-linux-gnu/usbdm/
sudo ldconfig
```

## udev Rules

The upstream udev rules file (`/etc/udev/rules.d/46-usbdm.rules`) uses
`TAG+="uaccess"` for most devices. This works for local console sessions but
**not for remote/SSH access** (including VS Code Remote). The USBDM BDM device
(vendor `16d0`, product `0567`) already has `MODE="0666"` added:

```
SUBSYSTEM=="usb", ATTR{idVendor}=="16d0", ATTR{idProduct}=="0567", SYMLINK+="usbdm%n", MODE="0666", TAG+="uaccess"
```

If other USBDM device variants also need remote access, add `MODE="0666"` to
their rules as well. After editing:

```bash
sudo udevadm control --reload-rules
sudo udevadm trigger
```

## Known Issues and Fixes

### 1. vCont Compound Command Parser (GdbHandlerCommon.cpp)

**Problem:** GDB 16.3+ sends compound `vCont` commands like
`vCont;c:-1;s:1` (meaning "continue all threads except thread 1, which should
step"). The original code dispatched via `strStartsWith("vCont;c", cmd)` and
`strStartsWith("vCont;s", cmd)` -- whichever matched first won. A compound
command starting with `c` would always call `continueTarget()` even when a
step action was present, breaking single-stepping.

**Fix:** Replaced the `strStartsWith`-based dispatch with a proper compound
parser in `doVContCommands()`. The parser scans all semicolon-delimited
actions and picks the highest-priority one (step > halt > continue). The
relevant code is in `GdbServer/src/GdbHandlerCommon.cpp`, around line 1329:

```cpp
// Parse all actions in the compound vCont command.
// For a single-threaded target we pick the highest-priority action:
//   step ('s') > halt ('t') > continue ('c')
bool hasStep     = false;
bool hasContinue = false;
bool hasHalt     = false;

const char *cPtr = cmd + sizeof("vCont") - 1;  // points at first ';'
while (*cPtr == ';') {
    cPtr++;  // skip ';'
    char action = *cPtr++;
    switch (action) {
        case 's': hasStep     = true; break;
        case 'c': hasContinue = true; break;
        case 't': hasHalt     = true; break;
    }
    // Skip optional thread-id (everything until next ';' or end)
    while (*cPtr != '\0' && *cPtr != ';') cPtr++;
}
```

The server also advertises `vContSupported+` in its `qSupported` response so
GDB knows it can use compound `vCont` commands.

### 2. CFV1_CSR_SSM Typo (TargetDefines.h) -- Already Fixed

**Problem:** Extra closing parenthesis: `(1UL<<4UL))`.

**Fix:** Corrected to `(1UL<<4UL)`. Current source at
`Shared/src/TargetDefines.h` line 183 is correct:

```cpp
#define CFV1_CSR_SSM             (1UL<<4UL)     //!< Single Step mode
```

### 3. sscanf Return Value for Step Address Parsing

**Problem:** The `'s'` (step) and `'c'` (continue) command handlers use
`sscanf(pkt->buffer, "s%X", &address)` with an `== 1` check, which is
correct. An earlier version may have used `> 1` which would never match a
single format specifier, causing the optional address to always be ignored.

**Current code** (line 1517) is correct:

```cpp
if (sscanf(pkt->buffer, "s%X", &address) == 1) {
```

### 4. Headless Operation (Xvfb)

**Problem:** USBDM tools are built with wxWidgets and require a display
(`DISPLAY` environment variable) even when run from the command line. Over SSH
or in a VS Code Remote session there is no display, and the GDB server crashes
on startup.

**Fix:** Use `Xvfb` (X Virtual Framebuffer) to provide a dummy display. The
recommended pattern is a wrapper script:

```bash
#!/bin/bash
pkill -f UsbdmGdbServer 2>/dev/null
pkill -f 'Xvfb :88' 2>/dev/null
sleep 1

# USB device reset (vendor 16d0 = USBDM)
USBDEV=$(ls /sys/bus/usb/devices/ 2>/dev/null | while read d; do
    [ -f "/sys/bus/usb/devices/$d/idVendor" ] && \
    grep -q 16d0 "/sys/bus/usb/devices/$d/idVendor" 2>/dev/null && echo "$d"
done)
if [ -n "$USBDEV" ]; then
    sudo sh -c "echo '$USBDEV' > /sys/bus/usb/drivers/usb/unbind" 2>/dev/null
    sleep 1
    sudo sh -c "echo '$USBDEV' > /sys/bus/usb/drivers/usb/bind" 2>/dev/null
    sleep 2
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

Key points:
- `setsid` detaches the processes so they survive the parent shell exiting
- Display `:88` avoids conflicts with any real X session
- The script waits up to 15 seconds for the server to begin listening on
  port 1234
- USB reset is needed because the BDM device can get stuck after a
  flash/debug session

### 5. The `-vdd=3V3` Flag

The `-vdd=3V3` flag tells the USBDM pod to supply 3.3 V to the target via its
VDD pin. **Omit this flag when the target has its own power supply.** Driving
VDD into an externally-powered target can cause contention and damage.

Typical invocation for an externally-powered target:

```bash
UsbdmGdbServer -target=cfv1 -device=MCF51JM128 -port=1234
```
