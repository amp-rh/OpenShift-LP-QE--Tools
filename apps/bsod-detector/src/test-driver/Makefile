CC = x86_64-w64-mingw32-gcc

# Driver build requires WDK headers; set WDK_INCLUDE to their location
WDK_INCLUDE ?= /usr/share/mingw-w64/include/ddk

CFLAGS_USER = -Wall -Wextra -O2
CFLAGS_KERN = -Wall -Wextra -O2 -I$(WDK_INCLUDE) \
	-D_WIN64 -D_AMD64_ -DNTDDI_VERSION=0x0A000000 -D_NTDDK_ -D_NTDDK_SHIM

LDFLAGS_KERN = -nostdlib -nostartfiles -shared \
	-Wl,--subsystem,native \
	-Wl,--entry,DriverEntry \
	-L. -lntoskrnl

.PHONY: all ctl driver clean

all: ctl driver

ctl: crashme-ctl.exe

driver: crashme.sys

crashme-ctl.exe: crashme-ctl.c
	$(CC) $(CFLAGS_USER) -o $@ $<

crashme.sys: crashme.c libntoskrnl.a
	$(CC) $(CFLAGS_KERN) -nostdlib -nostartfiles -shared -Wl,--subsystem,native -Wl,--entry,DriverEntry -o $@ $< -L. -lntoskrnl

libntoskrnl.a: ntoskrnl.def
	x86_64-w64-mingw32-dlltool -d $< -l $@ -k

clean:
	rm -f crashme-ctl.exe crashme.sys
