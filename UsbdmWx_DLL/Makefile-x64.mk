include ../Common.mk

TARGET = usbdm-wx-plugin

DEFS = -DMINIMAL_APP=wxPluginApp

$(TARGET)::
	@echo ''
	@echo  Building $@ 64-bit
	@echo "================================================================"
	$(MAKE) dll -f Target.mk BUILDDIR=$@ CDEFS='$(DEFS) -DCOMPILE_WX_PLUGIN_DLL' BITNESS=64

$(TARGET)-debug::
	@echo ''
	@echo  Building $@ 64-bit
	@echo "================================================================"
	$(MAKE) dll -f Target.mk BUILDDIR=$@ CDEFS='$(DEFS) -DCOMPILE_WX_PLUGIN_DLL' DEBUG='Y' BITNESS=64

TestWx-debug::
	@echo ''
	@echo  Building $@ 64-bit
	@echo "================================================================"
	$(MAKE) exe -f Target.mk BUILDDIR=$@ MODULE=TestWx TARGET=$@ CDEFS='$(DEFS)' DEBUG='Y' BITNESS=64

all:: $(TARGET) $(TARGET)-debug
# TestWx-debug skipped -- it's a sample/test EXE that doesn't compile under
# wxWidgets 3.2's winundef.h (LPCTSTR vs LPCSTR clash). The actual
# usbdm-wx-plugin.4.dll and every downstream consumer (GdbServer,
# Programmer_DLL, BdmInterface_DLL) build fine without it. Restore the
# `all:: TestWx-debug` line below once wx 3.2 is properly ported.
#all:: TestWx-debug

clean::
	-${RMDIR} $(TARGET)$(BUILDDIR_SUFFIXx64) $(TARGET)-debug$(BUILDDIR_SUFFIXx64)
	-${RMDIR} TestWx-debug$(BUILDDIR_SUFFIXx64)

.PHONY: all clean 
.PHONY: $(TARGET) $(TARGET)-debug
.PHONY: TestWx-debug
