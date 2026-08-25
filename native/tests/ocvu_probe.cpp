#include <chrono>
#include <cstdio>
#include <cstring>
#include <thread>

#include "ocvu_test_platform.h"

int main(int argc, char** argv) {
    ocvu_test::suppress_crash_dialogs();

    if (argc < 2) {
        std::fprintf(stderr, "usage: ocvu_probe <mode>\n");
        return 2;
    }

    const char* mode = argv[1];

    if (std::strcmp(mode, "ok") == 0) {
        std::printf("probe ok\n");
        return 0;
    }

    if (std::strcmp(mode, "segfault") == 0) {
        std::fprintf(stderr, "probe: dereferencing null\n");
        std::fflush(stderr);
        volatile int* p = nullptr;
        *p = 1;
        return 0;
    }

    if (std::strcmp(mode, "hang") == 0) {
        std::fprintf(stderr, "probe: sleeping forever\n");
        std::fflush(stderr);
        for (;;) {
            std::this_thread::sleep_for(std::chrono::seconds(3600));
        }
    }

    if (std::strcmp(mode, "use-after-free") == 0) {
        int* p = new int[16];
        p[0] = 7;
        delete[] p;
        volatile int observed = p[0];  // ASan: heap-use-after-free
        std::printf("observed %d\n", static_cast<int>(observed));
        return 0;
    }

    // NOTE: この "leak" モードは現在どこからも呼ばれていない。CMake も
    // tools/dev.ps1 も CI も登録していない。MSVC の ASan には
    // LeakSanitizer が無く、リーク検出は M3 の Linux レーンに送ったため。
    // 「動いているリーク検出」と読まないこと。M3 で Linux 用の
    // expect-failure テストを足すときの土台として残してある。
    if (std::strcmp(mode, "leak") == 0) {
        int* p = new int[64];
        p[0] = 1;
        std::printf("leaked %d\n", p[0]);
        return 0;
    }

    std::fprintf(stderr, "probe: unknown mode '%s'\n", mode);
    return 2;
}
