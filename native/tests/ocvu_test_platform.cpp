#include "ocvu_test_platform.h"

#if defined(_WIN32)

#include <crtdbg.h>
#include <stdlib.h>
#include <windows.h>

namespace ocvu_test {

void suppress_crash_dialogs() {
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX |
                 SEM_NOOPENFILEERRORBOX);

    // abort() が "This application has requested the Runtime to terminate"
    // ダイアログを出さないようにする。
    _set_abort_behavior(0, _WRITE_ABORT_MSG | _CALL_REPORTFAULT);

    // CRT のアサートをダイアログではなく stderr に出す。
    const int reports[] = {_CRT_WARN, _CRT_ERROR, _CRT_ASSERT};
    for (int report : reports) {
        _CrtSetReportMode(report, _CRTDBG_MODE_FILE);
        _CrtSetReportFile(report, _CRTDBG_FILE_STDERR);
    }
}

}  // namespace ocvu_test

#else

namespace ocvu_test {

void suppress_crash_dialogs() {}

}  // namespace ocvu_test

#endif
