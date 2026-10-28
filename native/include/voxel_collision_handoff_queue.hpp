#pragma once

#include <cstdint>
#include <vector>

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>

namespace godot {

// Owns the collision handoff state machine. All methods run on the main thread; ObjectIDs make the
// queue robust when a source or absorbed body is retired before the handoff is ready.
class VoxelCollisionHandoffQueue : public Resource {
    GDCLASS(VoxelCollisionHandoffQueue, Resource)

    struct Ticket {
        int64_t transaction = 0;
        uint64_t fragment_id = 0;
        uint64_t source_body_id = 0;
        uint64_t source_shape_id = 0;
        int64_t source_revision = 0;
        std::vector<uint64_t> absorbed_ids;
        Vector3 impulse_center;
        double impulse_energy = 0.0;
        double impulse_radius = 0.0;
        int64_t ready_frame = -1;
        // The fragment has already been released, but the ticket retains the source's recook
        // priority until its physics revision catches up with the voxel revision.
        bool fragment_released = false;
    };

    std::vector<Ticket> tickets;

protected:
    static void _bind_methods();

public:
    void clear();
    int size() const;
    bool is_empty() const;
    bool contains_fragment(Object *p_fragment) const;
    bool enqueue(const Dictionary &p_ticket);
    void remove_body(Object *p_body);
    Object *select_pending_source() const;
    Array process(int64_t p_physics_frame);
};

} // namespace godot
