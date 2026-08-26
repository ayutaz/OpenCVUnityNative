#include "ocvu_mat_table.h"

#include <cstdint>
#include <mutex>
#include <vector>

namespace ocvu {
namespace {

struct Slot {
    cv::Mat mat;
    uint32_t generation = 1;  // 1 から始める。世代 0 の handle は作らない
    bool occupied = false;
};

/*
 * table は関数内 static にする。DLL アンロード時の破棄順序に依存しないため。
 * mutex は Unity のワーカースレッドから同時に呼ばれ得るので必須である。
 */
struct Table {
    std::mutex mutex;
    std::vector<Slot> slots;
    std::vector<uint32_t> free_indices;
};

Table& table() {
    static Table instance;
    return instance;
}

constexpr ocvu_mat_handle make_handle(uint32_t index, uint32_t generation) {
    return (static_cast<ocvu_mat_handle>(generation) << 32) | static_cast<ocvu_mat_handle>(index);
}

constexpr uint32_t handle_index(ocvu_mat_handle h) { return static_cast<uint32_t>(h & 0xFFFFFFFFu); }
constexpr uint32_t handle_generation(ocvu_mat_handle h) { return static_cast<uint32_t>(h >> 32); }

}  // namespace

ocvu_mat_handle mat_table_acquire(cv::Mat mat) {
    Table& t = table();
    std::lock_guard<std::mutex> lock(t.mutex);

    uint32_t index;
    if (!t.free_indices.empty()) {
        index = t.free_indices.back();
        t.free_indices.pop_back();
    } else {
        t.slots.emplace_back();
        index = static_cast<uint32_t>(t.slots.size() - 1);
    }

    Slot& slot = t.slots[index];
    slot.mat = std::move(mat);
    slot.occupied = true;
    return make_handle(index, slot.generation);
}

cv::Mat* mat_table_get(ocvu_mat_handle handle) {
    if (handle == OCVU_MAT_HANDLE_NONE) { return nullptr; }

    Table& t = table();
    std::lock_guard<std::mutex> lock(t.mutex);

    const uint32_t index = handle_index(handle);
    if (index >= t.slots.size()) { return nullptr; }

    Slot& slot = t.slots[index];
    if (!slot.occupied || slot.generation != handle_generation(handle)) { return nullptr; }
    return &slot.mat;
}

bool mat_table_release(ocvu_mat_handle handle) {
    if (handle == OCVU_MAT_HANDLE_NONE) { return false; }

    Table& t = table();
    std::lock_guard<std::mutex> lock(t.mutex);

    const uint32_t index = handle_index(handle);
    if (index >= t.slots.size()) { return false; }

    Slot& slot = t.slots[index];
    if (!slot.occupied || slot.generation != handle_generation(handle)) { return false; }

    slot.mat.release();
    slot.occupied = false;
    // 世代を進めることで、この索引の古い handle は以後すべて無効になる。
    // 一周して衝突するのは 2^32 回の解放後であり、実用上到達しない。
    ++slot.generation;
    t.free_indices.push_back(index);
    return true;
}

}  // namespace ocvu
