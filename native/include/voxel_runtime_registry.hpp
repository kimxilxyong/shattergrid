#pragma once

#include <cstdint>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>

#include "voxel_shape_data.hpp"

namespace godot {

// Incremental, data-only mirror of the runtime state used by VoxelWorld3D.
// SceneTree mutations remain in GDScript; census, lookup and budget planning live here.
class VoxelRuntimeRegistry : public Resource {
    GDCLASS(VoxelRuntimeRegistry, Resource)

    struct BodyRecord {
        bool dynamic = false;
        bool awake = false;
        bool structural = false;
        bool persistent = false;
        int boxes = 0;
        int voxels = 0;
        int64_t last_interaction_msec = 0;
    };

    struct ShapeRecord {
		Ref<VoxelShapeData> data;
        int64_t body_id = 0;
        int64_t canonical_revision = 0;
        int64_t notified_revision = 0;
        int64_t collision_revision = 0;
        bool collision_enabled = false;
        bool collision_rebuild_pending = false;
        bool collision_handoff_pending = false;
    };

    std::unordered_map<int64_t, BodyRecord> bodies;
    std::unordered_map<int64_t, ShapeRecord> shapes;
    std::unordered_set<int64_t> baked_collision_pending;
    // Without this index, removing a body left its ShapeRecords orphaned: `data` is a Ref, so the
    // canonical revision kept advancing on a ghost and coherence reported it forever.
    std::unordered_map<int64_t, std::unordered_set<int64_t>> shapes_by_body;
    int dynamic_bodies = 0;
    int awake_bodies = 0;
    int compound_boxes = 0;
    int awake_compound_boxes = 0;

    void remove_body_totals(const BodyRecord &p_record);
    void add_body_totals(const BodyRecord &p_record);

protected:
    static void _bind_methods();

public:
    void clear();
    void upsert_body(int64_t p_body_id, bool p_dynamic, bool p_awake, bool p_structural,
            bool p_persistent, int p_boxes, int p_voxels, int64_t p_last_interaction_msec);
    void remove_body(int64_t p_body_id);
    void upsert_shape(int64_t p_shape_id, const Ref<VoxelShapeData> &p_data,
			int64_t p_body_id, int64_t p_canonical_revision,
            int64_t p_notified_revision, int64_t p_collision_revision, bool p_collision_enabled,
            bool p_collision_rebuild_pending, bool p_collision_handoff_pending);
    void remove_shape(int64_t p_shape_id);
    void set_baked_collision_pending(int64_t p_shape_id, bool p_pending);

    Dictionary get_metrics() const;
    Dictionary get_coherence_snapshot() const;
    PackedInt64Array get_awake_body_ids() const;
    PackedInt64Array get_zero_voxel_body_ids() const;
    Dictionary plan_budget(int p_target_awake_bodies, int p_burst_awake_bodies,
            int p_max_active_boxes, int p_max_boxes_per_body, bool p_burst) const;
};

} // namespace godot
