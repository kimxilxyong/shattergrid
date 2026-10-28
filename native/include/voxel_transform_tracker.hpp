#pragma once

#include <cstdint>
#include <unordered_set>

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>

namespace godot {

// Collects moving voxel shapes and render snapshots from the runtime registry's awake IDs. The
// tracker keeps exactly one frame of grace for bodies that have just gone to sleep.
class VoxelTransformTracker : public Resource {
    GDCLASS(VoxelTransformTracker, Resource)

    std::unordered_set<uint64_t> previous_awake;
    // A second frame captures the pose after Jolt applies sleeping/freeze asynchronously. With
    // only one frame, the Body could still advance by one tick, leaving rendering 9.8 cm behind.
    std::unordered_set<uint64_t> grace_awake;

protected:
    static void _bind_methods();

public:
    void reset();
    Dictionary collect(const PackedInt64Array &p_awake_body_ids);
};

} // namespace godot
