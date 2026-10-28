#include "voxel_transform_tracker.hpp"

#include <vector>

#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/array.hpp>

namespace godot {

void VoxelTransformTracker::_bind_methods() {
    ClassDB::bind_method(D_METHOD("reset"), &VoxelTransformTracker::reset);
    ClassDB::bind_method(D_METHOD("collect", "awake_body_ids"),
            &VoxelTransformTracker::collect);
}

void VoxelTransformTracker::reset() {
    previous_awake.clear();
    grace_awake.clear();
}

Dictionary VoxelTransformTracker::collect(const PackedInt64Array &p_awake_body_ids) {
    std::unordered_set<uint64_t> current;
    current.reserve(static_cast<size_t>(p_awake_body_ids.size()));
    std::vector<uint64_t> candidates;
    candidates.reserve(static_cast<size_t>(p_awake_body_ids.size())
            + previous_awake.size() + grace_awake.size());
    for (int index = 0; index < p_awake_body_ids.size(); ++index) {
        const uint64_t id = static_cast<uint64_t>(p_awake_body_ids[index]);
        if (current.insert(id).second) {
            candidates.push_back(id);
        }
    }
    for (const uint64_t id : previous_awake) {
        if (current.count(id) == 0) {
            candidates.push_back(id);
        }
    }
    for (const uint64_t id : grace_awake) {
        if (current.count(id) == 0 && previous_awake.count(id) == 0) {
            candidates.push_back(id);
        }
    }

    Array shapes;
    Array transforms;
    Array bounds;
    PackedInt64Array body_ids;
    for (const uint64_t body_id : candidates) {
        Object *body = ObjectDB::get_instance(body_id);
        if (body == nullptr || !body->has_method("get_shapes")) {
            continue;
        }
        const Array body_shapes = body->call("get_shapes");
        for (int shape_index = 0; shape_index < body_shapes.size(); ++shape_index) {
            Object *shape_object = body_shapes[shape_index];
            Node3D *shape = Object::cast_to<Node3D>(shape_object);
            if (shape == nullptr || !shape->is_inside_tree() ||
                    !shape->has_method("voxel_count") ||
                    static_cast<int64_t>(shape->call("voxel_count")) <= 0) {
                continue;
            }
            shapes.append(shape);
            // While moving, use the interpolated sample. During the grace frame after
            // On sleep, seal the canonical pose: interpolation can otherwise retain the previous
            // sample indefinitely if the Body slept or was reparented between ticks.
            transforms.append(current.count(body_id) != 0
                    ? shape->get_global_transform_interpolated()
                    : shape->get_global_transform());
            bounds.append(shape->has_method("world_bounds")
                    ? static_cast<AABB>(shape->call("world_bounds")) : AABB());
            body_ids.append(static_cast<int64_t>(body_id));
        }
    }
    std::unordered_set<uint64_t> next_grace;
    next_grace.reserve(previous_awake.size());
    for (const uint64_t id : previous_awake) {
        if (current.count(id) == 0) {
            next_grace.insert(id);
        }
    }
    grace_awake = std::move(next_grace);
    previous_awake = std::move(current);

    Dictionary result;
    result["shapes"] = shapes;
    result["transforms"] = transforms;
    result["bounds"] = bounds;
    result["body_ids"] = body_ids;
    return result;
}

} // namespace godot
