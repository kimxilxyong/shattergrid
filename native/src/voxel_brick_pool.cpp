#include "voxel_brick_pool.hpp"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/typed_array.hpp>

#include <cstring>

using namespace godot;

void VoxelBrickPool::_bind_methods() {
    ClassDB::bind_method(D_METHOD("configure", "grid"), &VoxelBrickPool::configure);
    ClassDB::bind_method(D_METHOD("reset"), &VoxelBrickPool::reset);
    ClassDB::bind_method(D_METHOD("get_grid"), &VoxelBrickPool::get_grid);
    ClassDB::bind_method(D_METHOD("get_dimensions"), &VoxelBrickPool::get_dimensions);
    ClassDB::bind_method(D_METHOD("get_capacity"), &VoxelBrickPool::get_capacity);
    ClassDB::bind_method(D_METHOD("get_used"), &VoxelBrickPool::get_used);
    ClassDB::bind_method(D_METHOD("get_bytes"), &VoxelBrickPool::get_bytes);
    ClassDB::bind_method(D_METHOD("get_slot_origin", "slot"), &VoxelBrickPool::get_slot_origin);
    ClassDB::bind_method(D_METHOD("append_shape", "data"), &VoxelBrickPool::append_shape);
    ClassDB::bind_method(D_METHOD("refresh_brick", "data", "slot", "macro"),
            &VoxelBrickPool::refresh_brick);
    ClassDB::bind_method(D_METHOD("extract_uploads", "base", "count"),
            &VoxelBrickPool::extract_uploads);
}

bool VoxelBrickPool::configure(const Vector3i &p_grid) {
    if (p_grid.x <= 0 || p_grid.y <= 0 || p_grid.z <= 0) {
        return false;
    }
    const int64_t cells = static_cast<int64_t>(p_grid.x) * p_grid.y * p_grid.z * BRICK_CELLS;
    if (cells > (1LL << 31)) {
        return false;
    }
    grid = p_grid;
    used = 0;
    bytes.resize(cells);
    memset(bytes.ptrw(), VoxelShapeData::AIR, static_cast<size_t>(cells));
    return true;
}

void VoxelBrickPool::reset() {
    used = 0;
    if (!bytes.is_empty()) {
        memset(bytes.ptrw(), VoxelShapeData::AIR, static_cast<size_t>(bytes.size()));
    }
}

Vector3i VoxelBrickPool::get_grid() const {
    return grid;
}

Vector3i VoxelBrickPool::get_dimensions() const {
    return grid * BRICK;
}

int VoxelBrickPool::get_capacity() const {
    return grid.x * grid.y * grid.z;
}

int VoxelBrickPool::get_used() const {
    return used;
}

PackedByteArray VoxelBrickPool::get_bytes() const {
    return bytes;
}

Vector3i VoxelBrickPool::get_slot_origin(int p_slot) const {
    if (p_slot < 0 || grid.x <= 0 || grid.y <= 0) {
        return Vector3i();
    }
    return Vector3i(p_slot % grid.x, (p_slot / grid.x) % grid.y, p_slot / (grid.x * grid.y)) * BRICK;
}

void VoxelBrickPool::write_brick_cells(const VoxelShapeData &p_data, int p_slot, int p_mx, int p_my, int p_mz) {
    const Vector3i source_size = p_data.get_dimensions();
    const PackedByteArray source = p_data.get_cells();
    const uint8_t *read = source.ptr();
    uint8_t *write = bytes.ptrw();
    const Vector3i texture = get_dimensions();
    const Vector3i origin = get_slot_origin(p_slot);
    // Shape edges can leave partial bricks: the remainder stays as air, which is already set.
    const int span_x = MIN(BRICK, source_size.x - p_mx * BRICK);
    if (span_x <= 0) {
        return;
    }
    for (int z = 0; z < BRICK; ++z) {
        const int source_z = p_mz * BRICK + z;
        if (source_z >= source_size.z) {
            break;
        }
        for (int y = 0; y < BRICK; ++y) {
            const int source_y = p_my * BRICK + y;
            if (source_y >= source_size.y) {
                break;
            }
            const int64_t from = static_cast<int64_t>(p_mx) * BRICK
                    + static_cast<int64_t>(source_y) * source_size.x
                    + static_cast<int64_t>(source_z) * source_size.x * source_size.y;
            const int64_t to = static_cast<int64_t>(origin.x)
                    + static_cast<int64_t>(origin.y + y) * texture.x
                    + static_cast<int64_t>(origin.z + z) * texture.x * texture.y;
            memcpy(write + to, read + from, static_cast<size_t>(span_x));
        }
    }
}

PackedInt32Array VoxelBrickPool::append_shape(const Ref<VoxelShapeData> &p_data) {
    PackedInt32Array table;
    if (p_data.is_null()) {
        return table;
    }
    const Vector3i macro_size = p_data->get_macro_dimensions();
    const int64_t macro_count = static_cast<int64_t>(macro_size.x) * macro_size.y * macro_size.z;
    if (macro_count <= 0) {
        return table;
    }
    const PackedInt32Array occupied = p_data->get_occupied_macros();
    if (used + occupied.size() > get_capacity()) {
        return table;
    }
    table.resize(macro_count);
    int32_t *entries = table.ptrw();
    for (int64_t index = 0; index < macro_count; ++index) {
        entries[index] = -1;
    }
    const int plane = macro_size.x * macro_size.y;
    for (int index = 0; index < occupied.size(); ++index) {
        const int macro = occupied[index];
        if (macro < 0 || macro >= macro_count) {
            continue;
        }
        const int slot = used + index;
        write_brick_cells(**p_data, slot, macro % macro_size.x,
                (macro / macro_size.x) % macro_size.y, macro / plane);
        entries[macro] = slot;
    }
    used += occupied.size();
    return table;
}

// Registering a Shape uploaded its bricks one at a time: 260,672 staging textures and 260,672
// `texture_copy` calls to load the Teardown map. `update_compact_regions` accepts one packed source
// and N copies, so bricks are stacked along Z here—the i-th brick occupies [512i, 512i+512), the
// exact order for an 8x8x8N volume—and the destination list is supplied. Each batch contains 256
// bricks because 8*256 = 2048 is the typical maximum depth of a 3D texture and is a power of two,
// so the atlas needs no padding.
Array VoxelBrickPool::extract_uploads(int p_base, int p_count) const {
    constexpr int CHUNK = 256;
    Array uploads;
    if (p_base < 0 || p_count <= 0 || p_base + p_count > used) {
        return uploads;
    }
    const uint8_t *read = bytes.ptr();
    const Vector3i texture = get_dimensions();
    for (int first = 0; first < p_count; first += CHUNK) {
        const int span = MIN(CHUNK, p_count - first);
        PackedByteArray packed;
        packed.resize(static_cast<int64_t>(span) * BRICK_CELLS);
        uint8_t *write = packed.ptrw();
        TypedArray<Dictionary> copies;
        for (int i = 0; i < span; ++i) {
            const Vector3i origin = get_slot_origin(p_base + first + i);
            for (int z = 0; z < BRICK; ++z) {
                for (int y = 0; y < BRICK; ++y) {
                    const int64_t from = static_cast<int64_t>(origin.x)
                            + static_cast<int64_t>(origin.y + y) * texture.x
                            + static_cast<int64_t>(origin.z + z) * texture.x * texture.y;
                    memcpy(write + (static_cast<int64_t>(i) * BRICK_CELLS + y * BRICK
                                   + z * BRICK * BRICK),
                            read + from, BRICK);
                }
            }
            Dictionary copy;
            copy["source"] = Vector3i(0, 0, i * BRICK);
            copy["destination"] = origin;
            copy["size"] = Vector3i(BRICK, BRICK, BRICK);
            copies.push_back(copy);
        }
        Dictionary upload;
        upload["bytes"] = packed;
        upload["source_size"] = Vector3i(BRICK, BRICK, span * BRICK);
        upload["copies"] = copies;
        uploads.push_back(upload);
    }
    return uploads;
}

PackedByteArray VoxelBrickPool::refresh_brick(const Ref<VoxelShapeData> &p_data, int p_slot,
        const Vector3i &p_macro) {
    PackedByteArray brick;
    if (p_data.is_null() || p_slot < 0 || p_slot >= used) {
        return brick;
    }
    write_brick_cells(**p_data, p_slot, p_macro.x, p_macro.y, p_macro.z);
    brick.resize(BRICK_CELLS);
    uint8_t *write = brick.ptrw();
    const uint8_t *read = bytes.ptr();
    const Vector3i texture = get_dimensions();
    const Vector3i origin = get_slot_origin(p_slot);
    for (int z = 0; z < BRICK; ++z) {
        for (int y = 0; y < BRICK; ++y) {
            const int64_t from = static_cast<int64_t>(origin.x)
                    + static_cast<int64_t>(origin.y + y) * texture.x
                    + static_cast<int64_t>(origin.z + z) * texture.x * texture.y;
            memcpy(write + (y * BRICK + z * BRICK * BRICK), read + from, BRICK);
        }
    }
    return brick;
}
