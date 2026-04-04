#!/bin/bash
# vs-code-install.sh -- Set up VS Code + USBDM debugging environment
# Safe to run multiple times (idempotent).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
USBDM_DIR="$SCRIPT_DIR"
TEMPLATE_DIR="${1:-$HOME/USBDM-Project-Template}"

echo "=== USBDM VS Code Setup ==="
echo ""

# ---------------------------------------------------------------
# 1. Install required packages
# ---------------------------------------------------------------
echo "[1/6] Installing packages..."
sudo apt install -y \
    xvfb xdotool gdb-multiarch \
    gcc-13-m68k-linux-gnu binutils-m68k-linux-gnu

# ---------------------------------------------------------------
# 2. Build m68k-elf-gdb from source if not present
# ---------------------------------------------------------------
if [ -x /usr/local/bin/m68k-elf-gdb ]; then
    echo "[2/6] m68k-elf-gdb already installed, skipping."
else
    echo "[2/6] Building m68k-elf-gdb from source..."
    echo "      (This takes several minutes.)"

    sudo apt install -y libgmp-dev libmpfr-dev libexpat1-dev \
        texinfo bison flex

    BUILD_TMP="$(mktemp -d)"
    trap "rm -rf '$BUILD_TMP'" EXIT

    GDB_VERSION="16.3"
    cd "$BUILD_TMP"
    if [ ! -f "gdb-${GDB_VERSION}.tar.xz" ]; then
        wget -q "https://ftp.gnu.org/gnu/gdb/gdb-${GDB_VERSION}.tar.xz"
    fi
    tar xf "gdb-${GDB_VERSION}.tar.xz"
    mkdir -p "gdb-${GDB_VERSION}/build"
    cd "gdb-${GDB_VERSION}/build"
    ../configure --target=m68k-elf --prefix=/usr/local \
        --disable-nls --disable-werror --with-python=no \
        --disable-sim --disable-gas --disable-binutils --disable-ld --disable-gold
    make -j"$(nproc)"
    sudo make install

    trap - EXIT
    rm -rf "$BUILD_TMP"

    echo "      m68k-elf-gdb installed to /usr/local/bin/m68k-elf-gdb"
fi

# ---------------------------------------------------------------
# 3. Install patched UsbdmGdbServer
# ---------------------------------------------------------------
GDBSERVER_SRC="$USBDM_DIR/PackageFiles/bin/aarch64-linux-gnu/UsbdmGdbServer"
if [ -f "$GDBSERVER_SRC" ]; then
    echo "[3/6] Installing patched UsbdmGdbServer..."
    sudo cp "$GDBSERVER_SRC" /usr/bin/UsbdmGdbServer
    echo "      Installed to /usr/bin/UsbdmGdbServer"
else
    echo "[3/6] WARNING: $GDBSERVER_SRC not found."
    echo "      Build it first: cd ~/USBDM/GdbServer && make -f Makefile-x64.mk UsbdmGdbServer"
fi

# ---------------------------------------------------------------
# 4. Update udev rules for remote/SSH access
# ---------------------------------------------------------------
UDEV_RULE="/etc/udev/rules.d/46-usbdm.rules"
echo "[4/6] Checking udev rules..."
if [ -f "$UDEV_RULE" ]; then
    # Check if the main USBDM device (16d0:0567) already has MODE="0666"
    if grep -q 'ATTR{idProduct}=="0567"' "$UDEV_RULE" && \
       ! grep 'ATTR{idProduct}=="0567"' "$UDEV_RULE" | grep -q 'MODE='; then
        echo "      Adding MODE=\"0666\" to USBDM device rule..."
        sudo sed -i '/ATTR{idProduct}=="0567"/ s/TAG+="uaccess"/MODE="0666", TAG+="uaccess"/' "$UDEV_RULE"
    else
        echo "      udev rules already have MODE set or rule not found, no changes needed."
    fi
else
    echo "      Creating $UDEV_RULE..."
    sudo tee "$UDEV_RULE" > /dev/null << 'RULES'
# USBDM udev rules -- allow unrestricted access for remote/SSH sessions
SUBSYSTEM=="usb", ATTR{idVendor}=="16d0", ATTR{idProduct}=="0567", SYMLINK+="usbdm%n", MODE="0666", TAG+="uaccess"
SUBSYSTEM=="usb", ATTR{idVendor}=="16d0", ATTR{idProduct}=="06a5", SYMLINK+="usbdm%n", MODE="0666", TAG+="uaccess"
SUBSYSTEM=="tty",  ATTRS{idVendor}=="16d0", TAG+="uaccess", SYMLINK+="ttyUsbdm%n"
RULES
fi

# ---------------------------------------------------------------
# 5. Reload udev
# ---------------------------------------------------------------
echo "[5/6] Reloading udev rules..."
sudo udevadm control --reload-rules
sudo udevadm trigger

# ---------------------------------------------------------------
# 6. Create template project directory
# ---------------------------------------------------------------
echo "[6/6] Creating template project in $TEMPLATE_DIR..."
mkdir -p "$TEMPLATE_DIR/.vscode"

# launch.json
cat > "$TEMPLATE_DIR/.vscode/launch.json" << 'EOF'
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
EOF

# tasks.json
cat > "$TEMPLATE_DIR/.vscode/tasks.json" << 'EOF'
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
EOF

# c_cpp_properties.json
cat > "$TEMPLATE_DIR/.vscode/c_cpp_properties.json" << 'EOF'
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
EOF

# settings.json
cat > "$TEMPLATE_DIR/.vscode/settings.json" << 'EOF'
{
    "C_Cpp.intelliSenseEngine": "Tag Parser",
    "C_Cpp.errorSquiggles": "disabled"
}
EOF

# intellisense_compat.h
cat > "$TEMPLATE_DIR/.vscode/intellisense_compat.h" << 'EOF'
/*
 * IntelliSense compatibility - VS Code defines __INTELLISENSE__ during parsing.
 * This file is force-included via c_cpp_properties.json.
 */
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
EOF

# start_gdbserver.sh
cat > "$TEMPLATE_DIR/start_gdbserver.sh" << 'SCRIPT'
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

# Adjust -target= and -device= for your MCU. Omit -vdd=3V3 if target has own power.
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
SCRIPT
chmod +x "$TEMPLATE_DIR/start_gdbserver.sh"

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Next steps:"
echo "  1. Copy $TEMPLATE_DIR to start a new project"
echo "  2. Edit .vscode/launch.json to point 'program' at your ELF file"
echo "  3. Edit start_gdbserver.sh to set -device= for your target MCU"
echo "  4. Open the project folder in VS Code"
echo "  5. Press Ctrl+Shift+B to build, then F5 to debug"
echo ""
echo "See arm.md and vs-code.md in the USBDM repository for full documentation."
