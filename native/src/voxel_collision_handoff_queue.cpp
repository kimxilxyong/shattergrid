#include "voxel_collision_handoff_queue.hpp"

#include <algorithm>

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/object.hpp>

namespace godot {

namespace {

uint64_t object_id_from_variant(const Variant &p_value) {
    Object *object = p_value;
    return object != nullptr ? object->get_instance_id() : 0;
}

bool source_rebuild_pending(Object *p_source, Object *p_shape, int64_t p_revision) {
    if (p_source == nullptr || p_shape == nullptr ||
            !p_source->has_method("is_static_collision_revision_pending")) {
        return false;
    }
    return static_cast<bool>(p_source->call(
            "is_static_collision_revision_pending", p_shape, p_revision));
}

bool source_handoff_pending(Object *p_source, Object *p_shape, int64_t p_revision) {
    if (p_source == nullptr || p_shape == nullptr) {
        return false;
    }
    if (p_source->has_method("is_static_collision_handoff_pending")) {
        return static_cast<bool>(p_source->call(
                "is_static_collision_handoff_pending", p_shape, p_revision));
    }
    return source_rebuild_pending(p_source, p_shape, p_revision);
}

} // namespace

void VoxelCollisionHandoffQueue::_bind_methods() {
    ClassDB::bind_method(D_METHOD("clear"), &VoxelCollisionHandoffQueue::clear);
    ClassDB::bind_method(D_METHOD("size"), &VoxelCollisionHandoffQueue::size);
    ClassDB::bind_method(D_METHOD("is_empty"), &VoxelCollisionHandoffQueue::is_empty);
    ClassDB::bind_method(D_METHOD("contains_fragment", "fragment"),
            &VoxelCollisionHandoffQueue::contains_fragment);
    ClassDB::bind_method(D_METHOD("enqueue", "ticket"),
            &VoxelCollisionHandoffQueue::enqueue);
    ClassDB::bind_method(D_METHOD("remove_body", "body"),
            &VoxelCollisionHandoffQueue::remove_body);
    ClassDB::bind_method(D_METHOD("select_pending_source"),
            &VoxelCollisionHandoffQueue::select_pending_source);
    ClassDB::bind_method(D_METHOD("process", "physics_frame"),
            &VoxelCollisionHandoffQueue::process);
}

void VoxelCollisionHandoffQueue::clear() {
    tickets.clear();
}

int VoxelCollisionHandoffQueue::size() const {
    return static_cast<int>(std::count_if(tickets.begin(), tickets.end(),
            [](const Ticket &ticket) { return !ticket.fragment_released; }));
}

bool VoxelCollisionHandoffQueue::is_empty() const {
    return size() == 0;
}

bool VoxelCollisionHandoffQueue::contains_fragment(Object *p_fragment) const {
    if (p_fragment == nullptr) {
        return false;
    }
    const uint64_t id = p_fragment->get_instance_id();
    return std::any_of(tickets.begin(), tickets.end(),
            [id](const Ticket &ticket) { return ticket.fragment_id == id; });
}

bool VoxelCollisionHandoffQueue::enqueue(const Dictionary &p_ticket) {
    Object *fragment = p_ticket.get("fragment", Variant());
    if (fragment == nullptr || contains_fragment(fragment)) {
        return false;
    }
    Ticket ticket;
    ticket.transaction = p_ticket.get("transaction", 0);
    ticket.fragment_id = fragment->get_instance_id();
    ticket.source_body_id = object_id_from_variant(p_ticket.get("source_body", Variant()));
    ticket.source_shape_id = object_id_from_variant(p_ticket.get("source_shape", Variant()));
    ticket.source_revision = p_ticket.get("source_revision", 0);
    const Array absorbed = p_ticket.get("absorbed", Array());
    ticket.absorbed_ids.reserve(static_cast<size_t>(absorbed.size()));
    for (int index = 0; index < absorbed.size(); ++index) {
        const uint64_t id = object_id_from_variant(absorbed[index]);
        if (id != 0) {
            ticket.absorbed_ids.push_back(id);
        }
    }
    ticket.impulse_center = p_ticket.get("impulse_center", Vector3());
    ticket.impulse_energy = p_ticket.get("impulse_energy", 0.0);
    ticket.impulse_radius = p_ticket.get("impulse_radius", 0.0);
    ticket.ready_frame = p_ticket.get("ready_frame", -1);
    tickets.push_back(std::move(ticket));
    return true;
}

void VoxelCollisionHandoffQueue::remove_body(Object *p_body) {
    if (p_body == nullptr) {
        return;
    }
    const uint64_t id = p_body->get_instance_id();
    for (int index = static_cast<int>(tickets.size()) - 1; index >= 0; --index) {
        Ticket &ticket = tickets[static_cast<size_t>(index)];
        if (ticket.fragment_id == id) {
            // This ticket was the only thing that would clear `collision_handoff_pending`. Cancel it
            // without re-enabling layers: `remove_body` is used only when retiring the node, and
            // completing the handoff would re-enable its ghost collision until end-of-frame
            // `queue_free`.
            if (p_body->has_method("cancel_collision_handoff")) {
                p_body->call("cancel_collision_handoff");
            }
            tickets.erase(tickets.begin() + index);
            continue;
        }
        if (ticket.source_body_id == id) {
            ticket.source_body_id = 0;
            ticket.source_shape_id = 0;
            ticket.source_revision = 0;
        }
        ticket.absorbed_ids.erase(std::remove(ticket.absorbed_ids.begin(),
                ticket.absorbed_ids.end(), id), ticket.absorbed_ids.end());
    }
}

Object *VoxelCollisionHandoffQueue::select_pending_source() const {
    for (const Ticket &ticket : tickets) {
        Object *source = ObjectDB::get_instance(ticket.source_body_id);
        Object *shape = ObjectDB::get_instance(ticket.source_shape_id);
        // Continue prioritizing the full rebuild even if the handoff can now be released.
        if (source_rebuild_pending(source, shape, ticket.source_revision)) {
            return source;
        }
    }
    return nullptr;
}

Array VoxelCollisionHandoffQueue::process(int64_t p_physics_frame) {
    Array cleanup_shapes;
    for (int index = static_cast<int>(tickets.size()) - 1; index >= 0; --index) {
        Ticket &ticket = tickets[static_cast<size_t>(index)];
        Object *fragment = ObjectDB::get_instance(ticket.fragment_id);
        if (fragment == nullptr) {
            tickets.erase(tickets.begin() + index);
            continue;
        }
        Object *source = ObjectDB::get_instance(ticket.source_body_id);
        Object *shape = ObjectDB::get_instance(ticket.source_shape_id);
        if (ticket.fragment_released) {
            if (!source_rebuild_pending(source, shape, ticket.source_revision)) {
                tickets.erase(tickets.begin() + index);
            }
            continue;
        }
        const bool source_pending =
                source_handoff_pending(source, shape, ticket.source_revision);
        bool absorbed_pending = false;
        for (const uint64_t absorbed_id : ticket.absorbed_ids) {
            Node *absorbed = Object::cast_to<Node>(ObjectDB::get_instance(absorbed_id));
            if (absorbed != nullptr && absorbed->is_inside_tree()) {
                absorbed_pending = true;
                break;
            }
        }
        if (source_pending || absorbed_pending) {
            ticket.ready_frame = -1;
            continue;
        }
        if (ticket.ready_frame < 0) {
            ticket.ready_frame = p_physics_frame + 1;
            continue;
        }
        if (p_physics_frame < ticket.ready_frame) {
            continue;
        }
        if (fragment->has_method("complete_collision_handoff")) {
            fragment->call("complete_collision_handoff", ticket.impulse_center,
                    ticket.impulse_energy, ticket.impulse_radius);
        }
        if (shape != nullptr) {
            cleanup_shapes.append(shape);
        }
        ticket.fragment_released = true;
        if (!source_rebuild_pending(source, shape, ticket.source_revision)) {
            tickets.erase(tickets.begin() + index);
        }
    }
    return cleanup_shapes;
}

} // namespace godot
