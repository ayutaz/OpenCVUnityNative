#include "ocvu_error.h"

#include <cstring>

namespace {

/*
 * メッセージは std::string ではなく固定長 thread_local バッファに保持する。
 *
 * 1. set_last_error は OCVU_TRY_END の catch(std::bad_alloc) の中からも
 *    呼ばれる。std::string の代入はアロケートし得るので、メモリ逼迫下では
 *    そこで再び bad_alloc が飛び、例外が extern "C" 関数を抜けて ABI 境界を
 *    越える。固定長バッファなら set_last_error は決して throw しない。
 * 2. thread_local な非 trivial 型のデストラクタ実行順序（DLL アンロード時）に
 *    依存しなくなる。M3 の非 Windows レーンで効いてくる。
 */
thread_local ocvu_status g_last_status = OCVU_STATUS_OK;
thread_local char g_last_message[ocvu::kLastErrorMessageCapacity] = {0};
thread_local std::size_t g_last_message_length = 0;

/*
 * 先頭 length バイトで切ったときに末尾へ現れる不完全な UTF-8 シーケンスを削る。
 * 切り詰めても不正な UTF-8 を返さないための処理。
 * 入力が UTF-8 として解釈できない場合は length をそのまま返す（触らない）。
 */
std::size_t trim_to_utf8_boundary(const char* text, std::size_t length) noexcept {
    for (std::size_t back = 1; back <= 4 && back <= length; ++back) {
        const std::size_t i = length - back;
        const unsigned char b = static_cast<unsigned char>(text[i]);

        if ((b & 0xC0u) == 0x80u) {
            continue;  // 継続バイト。さらに前へ
        }

        std::size_t expected = 0;
        if ((b & 0x80u) == 0x00u) {
            expected = 1;
        } else if ((b & 0xE0u) == 0xC0u) {
            expected = 2;
        } else if ((b & 0xF0u) == 0xE0u) {
            expected = 3;
        } else if ((b & 0xF8u) == 0xF0u) {
            expected = 4;
        } else {
            return length;  // 不正な先頭バイト
        }

        return (i + expected <= length) ? length : i;
    }

    return length;  // 継続バイトが 4 つ以上続く。UTF-8 ではない
}

}  // namespace

namespace ocvu {

ocvu_status set_last_error(ocvu_status status, const char* message) noexcept {
    g_last_status = status;

    if (message == nullptr) {
        g_last_message[0] = '\0';
        g_last_message_length = 0;
        return status;
    }

    constexpr std::size_t max_bytes = kLastErrorMessageCapacity - 1;
    std::size_t length = std::strlen(message);
    if (length > max_bytes) {
        length = trim_to_utf8_boundary(message, max_bytes);
    }

    std::memcpy(g_last_message, message, length);
    g_last_message[length] = '\0';
    g_last_message_length = length;
    return status;
}

void clear_last_error() noexcept {
    g_last_status = OCVU_STATUS_OK;
    g_last_message[0] = '\0';
    g_last_message_length = 0;
}

}  // namespace ocvu

extern "C" ocvu_status ocvu_get_last_error_status(void) {
    return g_last_status;
}

extern "C" ocvu_status ocvu_get_last_error_message(char* buffer,
                                                   int32_t buffer_size,
                                                   int32_t* out_required_size) {
    if (out_required_size == nullptr) {
        return OCVU_STATUS_NULL_POINTER;
    }

    const std::size_t length = g_last_message_length;
    const int32_t required = static_cast<int32_t>(length) + 1;
    *out_required_size = required;

    if (buffer == nullptr || buffer_size < required) {
        return OCVU_STATUS_INVALID_ARGUMENT;
    }

    std::memcpy(buffer, g_last_message, length);
    buffer[length] = '\0';
    return OCVU_STATUS_OK;
}
