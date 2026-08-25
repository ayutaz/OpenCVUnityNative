#include <cstddef>

#include "ocvu_error.h"

namespace {

/*
 * opencv_unity_native.h の OCVU_STATUS_LIST から生成する。手で足さないこと。
 * status を増やす手順はリストに 1 行足すだけで、この表も定数も同時に増える。
 */
#define OCVU_STATUS_TABLE_ENTRY_(name, value) static_cast<int32_t>(value),
constexpr int32_t kStatusValues[] = {OCVU_STATUS_LIST(OCVU_STATUS_TABLE_ENTRY_)};
#undef OCVU_STATUS_TABLE_ENTRY_

constexpr int32_t kStatusCount =
    static_cast<int32_t>(sizeof(kStatusValues) / sizeof(kStatusValues[0]));

}  // namespace

/* 失敗しないので例外バリアで囲まない（ocvu_error.h の注記を参照）。 */
extern "C" int32_t ocvu_get_status_count(void) {
    return kStatusCount;
}

extern "C" ocvu_status ocvu_get_status_value(int32_t index, int32_t* out_value) {
    OCVU_TRY_BEGIN
    if (out_value == nullptr) {
        return ::ocvu::set_last_error(OCVU_STATUS_NULL_POINTER,
                                      "ocvu_get_status_value: out_value is NULL");
    }
    if (index < 0 || index >= kStatusCount) {
        return ::ocvu::set_last_error(OCVU_STATUS_INVALID_ARGUMENT,
                                      "ocvu_get_status_value: index out of range");
    }
    *out_value = kStatusValues[index];
    return OCVU_STATUS_OK;
    OCVU_TRY_END
}
