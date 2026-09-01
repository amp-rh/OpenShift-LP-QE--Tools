#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

#define CRASHME_IOCTL CTL_CODE(FILE_DEVICE_UNKNOWN, 0x800, METHOD_BUFFERED, FILE_ANY_ACCESS)

typedef struct _CRASHME_INPUT {
    ULONG BugCheckCode;
    ULONG_PTR Param1;
    ULONG_PTR Param2;
    ULONG_PTR Param3;
    ULONG_PTR Param4;
} CRASHME_INPUT;

static void usage(const char *prog)
{
    fprintf(stderr, "Usage: %s <hex-bugcheck-code> [p1] [p2] [p3] [p4]\n", prog);
    fprintf(stderr, "All values in hex (0x prefix optional).\n");
    exit(1);
}

int main(int argc, char *argv[])
{
    if (argc < 2)
        usage(argv[0]);

    CRASHME_INPUT input = {0};
    input.BugCheckCode = (ULONG)strtoul(argv[1], NULL, 16);
    if (argc > 2) input.Param1 = (ULONG_PTR)strtoull(argv[2], NULL, 16);
    if (argc > 3) input.Param2 = (ULONG_PTR)strtoull(argv[3], NULL, 16);
    if (argc > 4) input.Param3 = (ULONG_PTR)strtoull(argv[4], NULL, 16);
    if (argc > 5) input.Param4 = (ULONG_PTR)strtoull(argv[5], NULL, 16);

    printf("Triggering BugCheck 0x%lX (P1=0x%llX P2=0x%llX P3=0x%llX P4=0x%llX)\n",
           input.BugCheckCode, (unsigned long long)input.Param1,
           (unsigned long long)input.Param2, (unsigned long long)input.Param3,
           (unsigned long long)input.Param4);

    HANDLE hDevice = CreateFileA("\\\\.\\CrashMe", GENERIC_READ | GENERIC_WRITE,
                                  0, NULL, OPEN_EXISTING, 0, NULL);
    if (hDevice == INVALID_HANDLE_VALUE) {
        fprintf(stderr, "Failed to open \\\\.\\CrashMe (error %lu).\n", GetLastError());
        fprintf(stderr, "Is the CrashMe driver loaded? Run: sc start CrashMe\n");
        return 1;
    }

    DWORD bytesReturned;
    BOOL ok = DeviceIoControl(hDevice, CRASHME_IOCTL, &input, sizeof(input),
                              NULL, 0, &bytesReturned, NULL);
    if (!ok)
        fprintf(stderr, "DeviceIoControl failed (error %lu).\n", GetLastError());

    CloseHandle(hDevice);
    return ok ? 0 : 1;
}
