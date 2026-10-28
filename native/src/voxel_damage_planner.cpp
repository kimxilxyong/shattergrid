#include "voxel_damage_planner.hpp"

#include <chrono>

#include <godot_cpp/core/class_db.hpp>

namespace godot {

void VoxelDamagePlanner::_bind_methods() {
    ClassDB::bind_method(D_METHOD("damage_shape", "data", "center_voxels", "radius_voxels",
                                 "energy", "hardnesses", "foundation_threshold", "anchored",
                                 "guard_margin"),
            &VoxelDamagePlanner::damage_shape, DEFVAL(16));
    ClassDB::bind_method(D_METHOD("plan_detached_components", "components",
                                 "particle_voxel_limit"),
            &VoxelDamagePlanner::plan_detached_components);
}

Dictionary VoxelDamagePlanner::damage_shape(const Ref<VoxelShapeData> &p_data,
        const Vector3 &p_center_voxels, double p_radius_voxels, double p_energy,
        const PackedFloat32Array &p_hardnesses, double p_foundation_threshold, bool p_anchored,
        int p_guard_margin) const {
    if (p_data.is_null()) {
        return Dictionary();
    }
    Dictionary result = p_data->damage_sphere_material(p_center_voxels, p_radius_voxels, p_energy,
            p_hardnesses, p_foundation_threshold);
    const int removed = result.get("removed", 0);
    if (removed <= 0) {
        result["should_classify"] = false;
        result["guard_usec"] = static_cast<int64_t>(0);
        return result;
    }
    const int removed_foundation = result.get("removed_foundation", 0);
    bool should_classify = p_anchored || removed_foundation > 0;
    int64_t guard_usec = 0;
    if (!should_classify) {
        const auto started = std::chrono::steady_clock::now();
        const Vector3i dirty_min = result.get("dirty_min", Vector3i());
        const Vector3i dirty_max = result.get("dirty_max", Vector3i());
        const bool local_cut = p_data->damage_may_disconnect_6(
                dirty_min, dirty_max, p_guard_margin);
        should_classify = local_cut && p_data->damage_may_disconnect_6_indexed(
                dirty_min, dirty_max);
        guard_usec = std::chrono::duration_cast<std::chrono::microseconds>(
                std::chrono::steady_clock::now() - started).count();
    }
    result["should_classify"] = should_classify;
    result["guard_usec"] = guard_usec;
    return result;
}

// No crater-proximity filter. An island disconnected far from the impact has no path to the
// ground either; skipping it left it suspended forever. `_drop_unsupported` works per Shape, not
// per component, so it would never be checked again.
Array VoxelDamagePlanner::plan_detached_components(
        const Array &p_components, int p_particle_voxel_limit) const {
    Array result;
    for (int index = 0; index < p_components.size(); ++index) {
        const Dictionary component = p_components[index];
        if (static_cast<bool>(component.get("anchored", false))) {
            continue;
        }
        const int count = component.get("voxel_count", 0);
        if (count <= 0) {
            continue;
        }
        Dictionary decision;
        decision["component_index"] = index;
        decision["count"] = count;
        decision["particle_candidate"] = count <= p_particle_voxel_limit;
        result.append(decision);
    }
    return result;
}

} // namespace godot
