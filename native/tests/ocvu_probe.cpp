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
        /*
         * **この use-after-free は意図的である。消してはならない。**
         *
         * ASan レーンが本当に use-after-free を検出することを実証するための
         * プローブで、CMake が harness.use_after_free_is_detected として
         * expect-failure テストに登録している。ここが「正しい」コードに
         * なった瞬間、そのテストは緑のまま何も検証しなくなる——検査が
         * 静かに無力化される、このリポジトリが繰り返し踏んでいる形である。
         *
         * CodeQL は当然これを critical として報告する（cpp/use-after-free）。
         * 報告は正しい。**正しい報告に対して、意図的であることを明示する。**
         * 黙って抑制すると、次に読む人が「なぜ critical が出ないのか」を
         * 調べ直すことになる。
         */
        int* p = new int[16];
        p[0] = 7;
        delete[] p;
        // codeql[cpp/use-after-free] 意図的。ASan が検出することを確かめるプローブである。
        volatile int observed = p[0];  // ASan: heap-use-after-free
        std::printf("observed %d\n", static_cast<int>(observed));
        return 0;
    }

    // LeakSanitizer が動いている環境でのみ意味を持つ。native/tests/CMakeLists.txt
    // が MSVC 以外の ASan ビルドで harness.leak_is_detected として登録する
    // （MSVC の ASan は LeakSanitizer を含まないので、そこでは登録されない）。
    //
    // 意図的に解放しない。free する経路を足すとこのプローブは無意味になる。
    if (std::strcmp(mode, "leak") == 0) {
        int* p = new int[64];
        p[0] = 1;
        std::printf("leaked %d\n", p[0]);
        return 0;
    }

    std::fprintf(stderr, "probe: unknown mode '%s'\n", mode);
    return 2;
}
