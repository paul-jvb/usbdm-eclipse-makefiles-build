@echo off
REM vs-code-install.cmd -- Set up VS Code + USBDM debugging environment (Windows)
REM Safe to run multiple times (idempotent).
REM Run from the USBDM repository root directory.

setlocal enabledelayedexpansion

set "SCRIPT_DIR=%~dp0"
set "USBDM_DIR=%SCRIPT_DIR%"

REM Template directory -- override with first argument if provided
if "%~1"=="" (
    set "TEMPLATE_DIR=%USERPROFILE%\USBDM-Project-Template"
) else (
    set "TEMPLATE_DIR=%~1"
)

echo === USBDM VS Code Setup (Windows) ===
echo.

REM ---------------------------------------------------------------
REM 1. Check prerequisites
REM ---------------------------------------------------------------
echo [1/4] Checking prerequisites...

where code >nul 2>&1
if %errorlevel% neq 0 (
    echo       WARNING: VS Code ^(code^) not found in PATH.
    echo       Install from https://code.visualstudio.com/
)

where gdb-multiarch >nul 2>&1 || where m68k-elf-gdb >nul 2>&1
if %errorlevel% neq 0 (
    echo       WARNING: No GDB found ^(gdb-multiarch or m68k-elf-gdb^).
    echo       Install a cross-debugging capable GDB via MSYS2 or build from source.
    echo       MSYS2: pacman -S mingw-w64-x86_64-gdb-multiarch
)

REM ---------------------------------------------------------------
REM 2. Install patched UsbdmGdbServer
REM ---------------------------------------------------------------
echo [2/4] Checking UsbdmGdbServer...

set "GDBSERVER_SRC=%USBDM_DIR%PackageFiles\bin\x86_64-win-gnu\UsbdmGdbServer.exe"
if exist "%GDBSERVER_SRC%" (
    echo       Found: %GDBSERVER_SRC%
    echo       Copy to a directory on your PATH or use the full path in your launch config.
) else (
    set "GDBSERVER_SRC=%USBDM_DIR%PackageFiles\bin\i386-win-gnu\UsbdmGdbServer.exe"
    if exist "!GDBSERVER_SRC!" (
        echo       Found: !GDBSERVER_SRC!
        echo       Copy to a directory on your PATH or use the full path in your launch config.
    ) else (
        echo       WARNING: UsbdmGdbServer.exe not found in PackageFiles\bin.
        echo       Build it first: MakeAll from MSYS2 shell.
    )
)

REM ---------------------------------------------------------------
REM 3. Install USBDM USB drivers (reminder)
REM ---------------------------------------------------------------
echo [3/4] USB driver check...
echo       Ensure the USBDM USB drivers are installed.
echo       The USBDM installer or Zadig ^(https://zadig.akeo.ie^) can set up
echo       WinUSB/libusb drivers for the USBDM pod ^(VID 16D0, PID 0567^).

REM ---------------------------------------------------------------
REM 4. Create template project directory
REM ---------------------------------------------------------------
echo [4/4] Creating template project in %TEMPLATE_DIR%...

if not exist "%TEMPLATE_DIR%\.vscode" mkdir "%TEMPLATE_DIR%\.vscode"

REM launch.json
(
echo {
echo     "version": "0.2.0",
echo     "configurations": [
echo         {
echo             "name": "Debug (USBDM)",
echo             "type": "cppdbg",
echo             "request": "launch",
echo             "program": "${workspaceFolder}/build/firmware.elf",
echo             "cwd": "${workspaceFolder}",
echo             "MIMode": "gdb",
echo             "miDebuggerPath": "gdb-multiarch",
echo             "miDebuggerServerAddress": "localhost:1234",
echo             "stopAtEntry": true,
echo             "setupCommands": [
echo                 { "text": "set remotetimeout 10" },
echo                 { "text": "set mem inaccessible-by-default off" }
echo             ],
echo             "preLaunchTask": "Start GDB Server",
echo             "logging": {
echo                 "engineLogging": false,
echo                 "moduleLoad": false
echo             }
echo         }
echo     ]
echo }
) > "%TEMPLATE_DIR%\.vscode\launch.json"

REM tasks.json
(
echo {
echo     "version": "2.0.0",
echo     "tasks": [
echo         {
echo             "label": "Build",
echo             "type": "shell",
echo             "command": "make",
echo             "group": { "kind": "build", "isDefault": true },
echo             "problemMatcher": "$gcc"
echo         },
echo         {
echo             "label": "Clean",
echo             "type": "shell",
echo             "command": "make clean",
echo             "problemMatcher": []
echo         },
echo         {
echo             "label": "Flash",
echo             "type": "shell",
echo             "command": "make flash",
echo             "dependsOn": "Build",
echo             "problemMatcher": []
echo         },
echo         {
echo             "label": "Start GDB Server",
echo             "type": "shell",
echo             "command": "${workspaceFolder}/start_gdbserver.cmd",
echo             "problemMatcher": [],
echo             "presentation": { "reveal": "always", "panel": "dedicated" }
echo         }
echo     ]
echo }
) > "%TEMPLATE_DIR%\.vscode\tasks.json"

REM c_cpp_properties.json
(
echo {
echo     "configurations": [
echo         {
echo             "name": "MCF51JM128 (GCC m68k)",
echo             "compilerPath": "m68k-elf-gcc",
echo             "compilerArgs": ["-mcpu=51jm", "-ffreestanding"],
echo             "intelliSenseMode": "windows-gcc-x64",
echo             "includePath": ["${workspaceFolder}"],
echo             "cStandard": "c99"
echo         }
echo     ],
echo     "version": 4
echo }
) > "%TEMPLATE_DIR%\.vscode\c_cpp_properties.json"

REM settings.json
(
echo {
echo     "C_Cpp.intelliSenseEngine": "Tag Parser",
echo     "C_Cpp.errorSquiggles": "disabled"
echo }
) > "%TEMPLATE_DIR%\.vscode\settings.json"

REM intellisense_compat.h
(
echo /*
echo  * IntelliSense compatibility - VS Code defines __INTELLISENSE__ during parsing.
echo  * This file is force-included via c_cpp_properties.json.
echo  */
echo #ifdef __INTELLISENSE__
echo.
echo #ifdef __declspec
echo #undef __declspec
echo #endif
echo #define __declspec(x)
echo.
echo #ifdef asm
echo #undef asm
echo #endif
echo #define asm
echo.
echo #define __interrupt
echo.
echo #endif /* __INTELLISENSE__ */
) > "%TEMPLATE_DIR%\.vscode\intellisense_compat.h"

REM start_gdbserver.cmd
(
echo @echo off
echo REM Start USBDM GDB server for VS Code debugging (Windows)
echo REM Adjust -target= and -device= for your MCU.
echo REM Omit -vdd=3V3 if target has its own power supply.
echo.
echo REM Kill any existing GDB server
echo taskkill /f /im UsbdmGdbServer.exe 2^>nul
echo timeout /t 1 /nobreak ^>nul
echo.
echo REM Start the GDB server
echo start "" /b UsbdmGdbServer -target=cfv1 -device=MCF51JM128 -port=1234
echo.
echo REM Wait for the server to start listening
echo set RETRIES=0
echo :wait_loop
echo if %%RETRIES%% geq 30 goto fail
echo timeout /t 1 /nobreak ^>nul
echo netstat -an ^| findstr ":1234.*LISTENING" ^>nul 2^>^&1
echo if %%errorlevel%% equ 0 goto success
echo set /a RETRIES+=1
echo goto wait_loop
echo.
echo :success
echo echo GDB server ready on port 1234
echo exit /b 0
echo.
echo :fail
echo echo ERROR: GDB server failed to start
echo exit /b 1
) > "%TEMPLATE_DIR%\start_gdbserver.cmd"

echo.
echo === Setup Complete ===
echo.
echo Next steps:
echo   1. Copy %TEMPLATE_DIR% to start a new project
echo   2. Edit .vscode\launch.json to point 'program' at your ELF file
echo   3. Edit start_gdbserver.cmd to set -device= for your target MCU
echo   4. Open the project folder in VS Code
echo   5. Press Ctrl+Shift+B to build, then F5 to debug
echo.
echo See arm.md and vs-code.md in the USBDM repository for full documentation.

endlocal
