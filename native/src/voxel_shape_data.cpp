#include "voxel_shape_data.hpp"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <unordered_map>
#include <vector>

using namespace godot;

namespace {
constexpr int MAX_DAMAGE_SAMPLES = 256;
constexpr int SUPPORT_BAND_HEIGHT = 16;

uint32_t damage_sample_hash(uint32_t value) {
    value ^= value >> 16;
    value *= 0x7feb352du;
    value ^= value >> 15;
    value *= 0x846ca68bu;
    value ^= value >> 16;
    return value;
}

// Coherent 20 cm noise that eats into the crater rim. Per-voxel noise would leave speckle and
// orphan voxels; hashing 2x2x2 blocks makes the edge undulate in chunks instead. Never returns
// more than 1.0, so the carve never reaches outside the loop bounds computed from the radius.
double rim_shrink(int x, int y, int z) {
    const uint32_t key = static_cast<uint32_t>(x >> 1) * 73856093u
            ^ static_cast<uint32_t>(y >> 1) * 19349663u
            ^ static_cast<uint32_t>(z >> 1) * 83492791u;
    return 0.72 + (damage_sample_hash(key) & 0xffffu) / 65535.0 * 0.28;
}

void reservoir_damage_sample(PackedInt32Array &indices, PackedByteArray &materials,
        int voxel_index, uint8_t material, int removed_count) {
    if (indices.size() < MAX_DAMAGE_SAMPLES) {
        indices.append(voxel_index);
        materials.append(material);
        return;
    }
    // Deterministic reservoir sampling keeps representative material/position samples without
    // making cosmetic particle cost proportional to the crater volume.
    const uint32_t candidate = damage_sample_hash(
            static_cast<uint32_t>(voxel_index) ^ (static_cast<uint32_t>(removed_count) * 0x9e3779b9u));
    const int slot = static_cast<int>(candidate % static_cast<uint32_t>(removed_count));
    if (slot < MAX_DAMAGE_SAMPLES) {
        indices.set(slot, voxel_index);
        materials.set(slot, material);
    }
}
} // namespace

void VoxelShapeData::_bind_methods() {
    ClassDB::bind_method(D_METHOD("configure", "dimensions"), &VoxelShapeData::configure);
    ClassDB::bind_method(D_METHOD("set_cells", "dimensions", "cells"), &VoxelShapeData::set_cells);
    ClassDB::bind_method(D_METHOD("generate_prototype", "size"), &VoxelShapeData::generate_prototype, DEFVAL(64));
    ClassDB::bind_method(D_METHOD("get_dimensions"), &VoxelShapeData::get_dimensions);
    ClassDB::bind_method(D_METHOD("get_macro_dimensions"), &VoxelShapeData::get_macro_dimensions);
    ClassDB::bind_method(D_METHOD("get_cells"), &VoxelShapeData::get_cells);
    ClassDB::bind_method(D_METHOD("get_used_materials"), &VoxelShapeData::get_used_materials);
    ClassDB::bind_method(D_METHOD("get_macro_occupancy"), &VoxelShapeData::get_macro_occupancy);
    ClassDB::bind_method(D_METHOD("get_occupied_count"), &VoxelShapeData::get_occupied_count);
    ClassDB::bind_method(D_METHOD("get_content_revision"), &VoxelShapeData::get_content_revision);
    ClassDB::bind_method(D_METHOD("get_cell", "x", "y", "z"), &VoxelShapeData::get_cell);
    ClassDB::bind_method(D_METHOD("set_cell", "x", "y", "z", "material"), &VoxelShapeData::set_cell);
    ClassDB::bind_method(D_METHOD("get_occupied_macros"), &VoxelShapeData::get_occupied_macros);
    ClassDB::bind_method(D_METHOD("get_live_indices"), &VoxelShapeData::get_live_indices);
    ClassDB::bind_method(D_METHOD("get_live_indices_region", "low", "high"),
            &VoxelShapeData::get_live_indices_region);
    ClassDB::bind_method(D_METHOD("rasterize_occupancy_region", "transform", "voxel_size",
                                 "world_low", "logical_size", "cell_size", "packed_size", "target"),
            &VoxelShapeData::rasterize_occupancy_region);
    ClassDB::bind_method(D_METHOD("has_hardness_at_least", "hardnesses", "threshold"),
            &VoxelShapeData::has_hardness_at_least);
    ClassDB::bind_method(D_METHOD("count_hardness_at_least", "hardnesses", "threshold"),
            &VoxelShapeData::count_hardness_at_least);
    ClassDB::bind_method(D_METHOD("get_indices_hardness_at_least", "hardnesses", "threshold"),
            &VoxelShapeData::get_indices_hardness_at_least);
    ClassDB::bind_method(D_METHOD("touches", "other", "other_to_self", "self_voxel_size",
                                 "other_voxel_size", "margin", "max_scan"),
            &VoxelShapeData::touches, DEFVAL(0.0), DEFVAL(0));
    ClassDB::bind_method(D_METHOD("component_touches", "indices", "other", "other_to_self",
                                 "self_voxel_size", "other_voxel_size", "margin"),
            &VoxelShapeData::component_touches, DEFVAL(0.0));
    ClassDB::bind_method(D_METHOD("component_seed_touches", "seed_index", "other", "other_to_self",
                                 "self_voxel_size", "other_voxel_size", "margin"),
            &VoxelShapeData::component_seed_touches, DEFVAL(0.0));
    ClassDB::bind_static_method("VoxelShapeData",
            D_METHOD("rasterize_occupancy_level", "shapes", "transforms", "voxel_sizes",
                    "world_low", "logical_size", "cell_size", "packed_size"),
            &VoxelShapeData::rasterize_occupancy_level);
    ClassDB::bind_method(D_METHOD("set_cells_from_xyzi", "source_size", "xyzi"),
            &VoxelShapeData::set_cells_from_xyzi);
    ClassDB::bind_method(D_METHOD("hollow", "shell"), &VoxelShapeData::hollow);
    ClassDB::bind_method(
            D_METHOD("damage_sphere", "center_voxels", "radius_voxels", "energy"),
            &VoxelShapeData::damage_sphere, DEFVAL(1.0));
    ClassDB::bind_method(
            D_METHOD("damage_sphere_material", "center_voxels", "radius_voxels", "energy",
                    "hardnesses", "foundation_threshold"),
            &VoxelShapeData::damage_sphere_material, DEFVAL(-1.0));
    ClassDB::bind_method(D_METHOD("find_components_6"), &VoxelShapeData::find_components_6);
    ClassDB::bind_method(D_METHOD("find_components_6_with_anchors", "anchor_indices"),
            &VoxelShapeData::find_components_6_with_anchors);
    ClassDB::bind_method(D_METHOD("find_components_6_with_hardness_anchors", "hardnesses", "threshold"),
            &VoxelShapeData::find_components_6_with_hardness_anchors);
    ClassDB::bind_method(D_METHOD("find_components_6_with_anchors_reference", "anchor_indices"),
            &VoxelShapeData::find_components_6_with_anchors_reference);
    ClassDB::bind_method(D_METHOD("get_component_6", "seed_index"),
            &VoxelShapeData::get_component_6);
    ClassDB::bind_method(D_METHOD("get_connectivity_metrics"),
            &VoxelShapeData::get_connectivity_metrics);
    ClassDB::bind_method(D_METHOD("prepare_connectivity_index"),
            &VoxelShapeData::prepare_connectivity_index);
    ClassDB::bind_method(D_METHOD("damage_may_disconnect_6", "dirty_min", "dirty_max", "margin"),
            &VoxelShapeData::damage_may_disconnect_6, DEFVAL(16));
    ClassDB::bind_method(D_METHOD("damage_may_disconnect_6_indexed", "dirty_min", "dirty_max"),
            &VoxelShapeData::damage_may_disconnect_6_indexed);
    ClassDB::bind_method(D_METHOD("detach_component", "indices"), &VoxelShapeData::detach_component);
    ClassDB::bind_method(D_METHOD("detach_component_except", "indices", "retained_indices"),
            &VoxelShapeData::detach_component_except);
    ClassDB::bind_method(D_METHOD("build_collision_boxes", "max_boxes", "voxel_size"),
            &VoxelShapeData::build_collision_boxes, DEFVAL(128), DEFVAL(0.1));
    ClassDB::bind_method(
            D_METHOD("build_macro_faces", "macro", "voxel_size", "block", "lod", "collidable"),
            &VoxelShapeData::build_macro_faces, DEFVAL(0.1), DEFVAL(1), DEFVAL(1),
            DEFVAL(PackedByteArray()));
    ClassDB::bind_method(D_METHOD("calculate_mass_properties", "densities", "voxel_size"),
            &VoxelShapeData::calculate_mass_properties, DEFVAL(0.1));
    ClassDB::bind_method(D_METHOD("self_test"), &VoxelShapeData::self_test);

    ADD_PROPERTY(PropertyInfo(Variant::VECTOR3I, "dimensions"), "configure", "get_dimensions");
    ADD_PROPERTY(PropertyInfo(Variant::INT, "occupied_count", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_READ_ONLY), "", "get_occupied_count");
    ADD_PROPERTY(PropertyInfo(Variant::INT, "content_revision", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_READ_ONLY), "", "get_content_revision");
}

int VoxelShapeData::index_of(int x, int y, int z) const {
    return x + y * dimensions.x + z * dimensions.x * dimensions.y;
}

int VoxelShapeData::macro_index_of(int x, int y, int z) const {
    return x + y * macro_dimensions.x + z * macro_dimensions.x * macro_dimensions.y;
}

bool VoxelShapeData::in_bounds(int x, int y, int z) const {
    return x >= 0 && y >= 0 && z >= 0 && x < dimensions.x && y < dimensions.y && z < dimensions.z;
}

void VoxelShapeData::configure(const Vector3i &p_dimensions) {
    dimensions = Vector3i(
            std::max(1, p_dimensions.x),
            std::max(1, p_dimensions.y),
            std::max(1, p_dimensions.z));
    const int64_t cell_count = static_cast<int64_t>(dimensions.x) * dimensions.y * dimensions.z;
    ERR_FAIL_COND_MSG(cell_count > 512LL * 512LL * 512LL, "VoxelShapeData exceeds the 512^3 safety limit.");

    cells.resize(static_cast<int>(cell_count));
    cells.fill(AIR);
    occupied_count = 0;
    material_counts.fill(0);

    macro_dimensions = Vector3i(
            (dimensions.x + MACRO_SIZE - 1) / MACRO_SIZE,
            (dimensions.y + MACRO_SIZE - 1) / MACRO_SIZE,
            (dimensions.z + MACRO_SIZE - 1) / MACRO_SIZE);
    macro_occupancy.resize(macro_dimensions.x * macro_dimensions.y * macro_dimensions.z);
    macro_occupancy.fill(0);
    macro_connectivity.clear();
    macro_connectivity.resize(static_cast<size_t>(macro_occupancy.size()));
    connectivity_index_built = false;
    ++content_revision;
}

bool VoxelShapeData::set_cells(const Vector3i &p_dimensions, const PackedByteArray &p_cells) {
    const int64_t expected = static_cast<int64_t>(p_dimensions.x) * p_dimensions.y * p_dimensions.z;
    if (p_dimensions.x <= 0 || p_dimensions.y <= 0 || p_dimensions.z <= 0 || expected != p_cells.size()) {
        return false;
    }
    configure(p_dimensions);
    cells = p_cells.duplicate();
    occupied_count = 0;
    for (int i = 0; i < cells.size(); ++i) {
        const uint8_t material = cells[i];
        if (material != AIR) {
            ++occupied_count;
            ++material_counts[material];
        }
    }
    rebuild_macrocells();
    return true;
}

// Fills the volume straight from a MagicaVoxel XYZI payload (`x, y, z, index` per voxel, header
// already stripped) so the map importer never walks voxels in GDScript: one Teardown map is 27 M
// cells within 30 m of the spawn and a GDScript decode of that is tens of seconds of frozen startup.
//
// The axis swap is Teardown's, not MagicaVoxel's. Teardown-Converter writes the engine's own
// shape-local array verbatim and compensates in the XML with a +90 deg turn about X, which maps
// source (i, j, k) onto (i, k, -j). Mirroring j here rather than negating an axis keeps the volume
// in the positive octant the renderer and the collision builder assume.
bool VoxelShapeData::set_cells_from_xyzi(const Vector3i &p_source_size, const PackedByteArray &p_xyzi) {
    const Vector3i target(p_source_size.x, p_source_size.z, p_source_size.y);
    const int64_t expected = static_cast<int64_t>(target.x) * target.y * target.z;
    // This is the same limit enforced by `configure()`: below it, `cells` and `macro_occupancy`
    // are guaranteed to be correctly sized and zeroed, so the loop can write directly.
    if (target.x <= 0 || target.y <= 0 || target.z <= 0 || expected > 512LL * 512LL * 512LL) {
        return false;
    }
    configure(target);
    uint8_t *write = cells.ptrw();
    uint8_t *macros = macro_occupancy.ptrw();
    const uint8_t *read = p_xyzi.ptr();
    const int64_t voxels = p_xyzi.size() / 4;
    for (int64_t v = 0; v < voxels; ++v) {
        const uint8_t *entry = read + v * 4;
        const int i = entry[0];
        const int j = entry[1];
        const int k = entry[2];
        if (i >= p_source_size.x || j >= p_source_size.y || k >= p_source_size.z || entry[3] == AIR) {
            continue;
        }
        const int z = p_source_size.y - 1 - j;
        const int index = index_of(i, k, z);
        if (write[index] == AIR) {
            ++occupied_count;
        } else {
            --material_counts[write[index]];
        }
        write[index] = entry[3];
        ++material_counts[entry[3]];
        // Macrocell occupancy is known right here. `rebuild_macrocells()` used to rescan the entire
        // dense grid to derive the same result: 453 M cells per map and 2.2 s of load time.
        macros[macro_index_of(i / MACRO_SIZE, k / MACRO_SIZE, z / MACRO_SIZE)] = 1;
    }
    return true;
}

// Empties every voxel buried under `p_shell` solid neighbours on all six axes, leaving a shell of
// that thickness. Source `.vox` buildings are modelled solid: casa_dos_plantas is 1.44 M voxels in a
// 128 cube, almost all of it filler nobody can see and the player cannot stand in. Carving it out
// both cuts the volume several times over and turns the model into a building with rooms.
int VoxelShapeData::hollow(int p_shell) {
    if (cells.is_empty() || p_shell < 1) {
        return 0;
    }
    if (dimensions.x <= p_shell * 2 || dimensions.y <= p_shell * 2 || dimensions.z <= p_shell * 2) {
        return 0;
    }
    const uint8_t *read = cells.ptr();
    // Marked first and written after: eroding in place would let the same pass eat inwards through
    // the voxels it just cleared and hollow the model down to nothing.
    std::vector<int> doomed;
    for (int z = p_shell; z < dimensions.z - p_shell; ++z) {
        for (int y = p_shell; y < dimensions.y - p_shell; ++y) {
            for (int x = p_shell; x < dimensions.x - p_shell; ++x) {
                const int index = index_of(x, y, z);
                if (read[index] == AIR) {
                    continue;
                }
                bool buried = true;
                for (int step = 1; step <= p_shell && buried; ++step) {
                    buried = read[index_of(x + step, y, z)] != AIR
                            && read[index_of(x - step, y, z)] != AIR
                            && read[index_of(x, y + step, z)] != AIR
                            && read[index_of(x, y - step, z)] != AIR
                            && read[index_of(x, y, z + step)] != AIR
                            && read[index_of(x, y, z - step)] != AIR;
                }
                if (buried) {
                    doomed.push_back(index);
                }
            }
        }
    }
    uint8_t *write = cells.ptrw();
    for (const int index : doomed) {
        --material_counts[write[index]];
        write[index] = AIR;
    }
    occupied_count -= static_cast<int>(doomed.size());
    rebuild_macrocells();
    if (!doomed.empty()) {
        ++content_revision;
    }
    return static_cast<int>(doomed.size());
}

void VoxelShapeData::generate_prototype(int p_size) {
    const int size = std::clamp(p_size, 16, 128);
    configure(Vector3i(size, size, size));

    const int margin = std::max(2, size / 16);
    const int roof = std::max(8, size * 3 / 4);
    const int wall = std::max(1, size / 32);
    const int floor_stride = std::max(6, size / 5);

    uint8_t *write = cells.ptrw();
    for (int z = margin; z < size - margin; ++z) {
        for (int y = 0; y < roof; ++y) {
            for (int x = margin; x < size - margin; ++x) {
                const bool outer_x = x < margin + wall || x >= size - margin - wall;
                const bool outer_z = z < margin + wall || z >= size - margin - wall;
                const bool floor = y < wall || (y % floor_stride) < wall;
                const bool roof_voxel = y >= roof - wall;
                const bool pillar =
                        ((x < margin + wall * 2 || x >= size - margin - wall * 2) &&
                         (z < margin + wall * 2 || z >= size - margin - wall * 2));

                bool solid = outer_x || outer_z || floor || roof_voxel || pillar;
                // Regular window holes make depth errors and false proxy surfaces obvious.
                if ((outer_x || outer_z) && y > wall * 3 && (y % floor_stride) > wall * 2) {
                    const int horizontal = outer_x ? z : x;
                    if ((horizontal / std::max(2, wall * 3)) % 2 == 0) {
                        solid = floor || roof_voxel || pillar;
                    }
                }
                if (!solid) {
                    continue;
                }

                uint8_t material = 1;
                if (floor || roof_voxel) {
                    material = 2;
                } else if (pillar) {
                    material = 3;
                }
                write[index_of(x, y, z)] = material;
                ++occupied_count;
                ++material_counts[material];
            }
        }
    }
    rebuild_macrocells();
}

Vector3i VoxelShapeData::get_dimensions() const {
    return dimensions;
}

Vector3i VoxelShapeData::get_macro_dimensions() const {
    return macro_dimensions;
}

PackedByteArray VoxelShapeData::get_cells() const {
    return cells;
}

PackedByteArray VoxelShapeData::get_used_materials() const {
    // The scan covers the entire dense grid (453 M cells in the Teardown map) and used to write
    // cell by cell with PackedByteArray::set: 4.9 s of startup time. A raw pointer and a local table
    // make it a sequential read, and the final copy is 256 bytes.
    uint8_t seen[256] = {0};
    const uint8_t *source = cells.ptr();
    const int64_t count = cells.size();
    for (int64_t i = 0; i < count; ++i) {
        seen[source[i]] = 1;
    }
    // Air is representation, not a material used by the Shape.
    seen[AIR] = 0;
    PackedByteArray used;
    used.resize(256);
    memcpy(used.ptrw(), seen, 256);
    return used;
}

PackedByteArray VoxelShapeData::get_macro_occupancy() const {
    return macro_occupancy;
}

int VoxelShapeData::get_occupied_count() const {
    return occupied_count;
}

int64_t VoxelShapeData::get_content_revision() const {
    return content_revision;
}

int VoxelShapeData::get_cell(int p_x, int p_y, int p_z) const {
    if (!in_bounds(p_x, p_y, p_z)) {
        return AIR;
    }
    return cells[index_of(p_x, p_y, p_z)];
}

bool VoxelShapeData::set_cell(int p_x, int p_y, int p_z, int p_material) {
    if (!in_bounds(p_x, p_y, p_z)) {
        return false;
    }
    const uint8_t material = static_cast<uint8_t>(std::clamp(p_material, 0, 255));
    const int index = index_of(p_x, p_y, p_z);
    const uint8_t previous = cells[index];
    if (previous == material) {
        return false;
    }
    cells.set(index, material);
    if (previous != AIR) {
        --material_counts[previous];
    }
    if (material != AIR) {
        ++material_counts[material];
    }
    occupied_count += (previous == AIR && material != AIR) ? 1 : 0;
    occupied_count -= (previous != AIR && material == AIR) ? 1 : 0;
    rebuild_macrocell(p_x / MACRO_SIZE, p_y / MACRO_SIZE, p_z / MACRO_SIZE);
    ++content_revision;
    return true;
}

// Linear indices of macrocells that contain data. `rebuild_static_collision` traversed all three
// dimensions and called `build_macro_faces` for each one: on a Teardown map, that meant nearly two
// million native calls returning nothing, adding minutes to load time.
PackedInt32Array VoxelShapeData::get_occupied_macros() const {
    PackedInt32Array result;
    const uint8_t *occupancy = macro_occupancy.ptr();
    for (int i = 0; i < macro_occupancy.size(); ++i) {
        if (occupancy[i] != 0) {
            result.push_back(i);
        }
    }
    return result;
}

PackedInt32Array VoxelShapeData::get_live_indices() const {
    PackedInt32Array result;
    result.resize(occupied_count);
    int32_t *write = result.ptrw();
    const uint8_t *voxels = cells.ptr();
    int cursor = 0;
    for (int i = 0; i < cells.size(); ++i) {
        if (voxels[i] != AIR) {
            write[cursor++] = i;
        }
    }
    return result;
}

PackedInt32Array VoxelShapeData::get_live_indices_region(
        const Vector3i &p_low, const Vector3i &p_high) const {
    PackedInt32Array result;
    const Vector3i low(
            std::clamp(p_low.x, 0, dimensions.x),
            std::clamp(p_low.y, 0, dimensions.y),
            std::clamp(p_low.z, 0, dimensions.z));
    const Vector3i high(
            std::clamp(p_high.x, low.x, dimensions.x),
            std::clamp(p_high.y, low.y, dimensions.y),
            std::clamp(p_high.z, low.z, dimensions.z));
    for (int z = low.z; z < high.z; ++z) {
        for (int y = low.y; y < high.y; ++y) {
            for (int x = low.x; x < high.x; ++x) {
                const int index = index_of(x, y, z);
                if (cells[index] != AIR) {
                    result.append(index);
                }
            }
        }
    }
    return result;
}

// Recognize foundations: Teardown ground is `rock`, with hardness 1e6, and cannot be destroyed.
// Therefore, a Shape containing live rock is a foundation by definition. Return on the first
// matching voxel: Lee's terrain has 25 M cells and is rock from the first one, while a building
// (which never matches) has four orders of magnitude fewer cells to scan.
// Returning the maximum instead of a yes/no value required scanning the whole grid: 135 ms per shot.
bool VoxelShapeData::has_hardness_at_least(
        const PackedFloat32Array &p_hardnesses, double p_threshold) const {
    if (p_hardnesses.size() < 256) {
        return false;
    }
    const float *hardness = p_hardnesses.ptr();
    const uint8_t *read = cells.ptr();
    const int64_t count = cells.size();
    for (int64_t index = 0; index < count; ++index) {
        const uint8_t value = read[index];
        if (value != AIR && double(hardness[value]) >= p_threshold) {
            return true;
        }
    }
    return false;
}

int VoxelShapeData::count_hardness_at_least(
        const PackedFloat32Array &p_hardnesses, double p_threshold) const {
    if (p_hardnesses.size() < 256) {
        return 0;
    }
    const float *hardness = p_hardnesses.ptr();
    int64_t result = 0;
    for (int material = 1; material < 256; ++material) {
        if (double(hardness[material]) >= p_threshold) {
            result += material_counts[static_cast<size_t>(material)];
        }
    }
    return static_cast<int>(result);
}

PackedInt32Array VoxelShapeData::get_indices_hardness_at_least(
        const PackedFloat32Array &p_hardnesses, double p_threshold) const {
    PackedInt32Array result;
    if (p_hardnesses.size() < 256) {
        return result;
    }
    const float *hardness = p_hardnesses.ptr();
    const uint8_t *read = cells.ptr();
    const int64_t count = cells.size();
    for (int64_t index = 0; index < count; ++index) {
        const uint8_t value = read[index];
        if (value != AIR && double(hardness[value]) >= p_threshold) {
            result.append(static_cast<int32_t>(index));
        }
    }
    return result;
}

// Real contact between two voxel volumes: at least one live voxel in this volume has a box expanded
// by `p_margin` meters that contains a live voxel from the other. This is the primitive missing from
// the structural model: Teardown does not analyze stress, only whether a piece remains connected to
// the ground, and that connection can be indirect and pass through multiple Shapes. Overlapping
// bounding boxes are insufficient: AABBs of entire neighborhoods overlap, making everything
// appear connected to everything else.
//
// Limit the scan to the overlap of the two boxes, expressed in this volume's voxels, and stop at
// the first contact. The voxels of the called-on volume are scanned, so call this on the smaller one.
bool VoxelShapeData::touches(const Ref<VoxelShapeData> &p_other, const Transform3D &p_other_to_self,
        double p_self_voxel_size, double p_other_voxel_size, double p_margin,
        int p_max_scan) const {
    if (p_other.is_null() || p_self_voxel_size <= 0.0 || p_other_voxel_size <= 0.0) {
        return false;
    }
    const VoxelShapeData *other = p_other.ptr();
    const Transform3D self_to_other = p_other_to_self.affine_inverse();
    const Vector3 self_half = Vector3(dimensions) * 0.5;
    const Vector3 other_half = Vector3(other->dimensions) * 0.5;
    // The other volume's box, expressed in this volume's voxels, to limit the scan.
    Vector3 low(std::numeric_limits<double>::infinity(), std::numeric_limits<double>::infinity(),
            std::numeric_limits<double>::infinity());
    Vector3 high = -low;
    for (int corner = 0; corner < 8; ++corner) {
        const Vector3 other_local = Vector3(
                                           (corner & 1) ? double(other->dimensions.x) : 0.0,
                                           (corner & 2) ? double(other->dimensions.y) : 0.0,
                                           (corner & 4) ? double(other->dimensions.z) : 0.0) -
                other_half;
        const Vector3 in_self = p_other_to_self.xform(other_local * p_other_voxel_size) /
                        p_self_voxel_size +
                self_half;
        low = low.min(in_self);
        high = high.max(in_self);
    }
    const double margin_voxels = p_margin / p_self_voxel_size;
    const Vector3i scan_low(
            std::clamp(int(std::floor(low.x - margin_voxels)), 0, dimensions.x),
            std::clamp(int(std::floor(low.y - margin_voxels)), 0, dimensions.y),
            std::clamp(int(std::floor(low.z - margin_voxels)), 0, dimensions.z));
    const Vector3i scan_high(
            std::clamp(int(std::ceil(high.x + margin_voxels)), scan_low.x, dimensions.x),
            std::clamp(int(std::ceil(high.y + margin_voxels)), scan_low.y, dimensions.y),
            std::clamp(int(std::ceil(high.z + margin_voxels)), scan_low.z, dimensions.z));
    // Apply the margin in the OTHER volume's voxels, where the query is performed.
    const int reach = std::max(0, int(std::ceil(p_margin / p_other_voxel_size)));
    // An optional cap is only for approximate queries. Structural queries use zero (exact).
    // Exhausting the budget must never invent a material connection.
    int64_t budget = p_max_scan > 0 ? int64_t(p_max_scan) : std::numeric_limits<int64_t>::max();
    // Two pruning steps; without them, each call took 2.7 ms in Lee:
    //
    //  1. Macro-cells. Skip an empty 8x8x8 block at once: 512 cells in one operation.
    //  2. Surface only. A voxel with six solid neighbors cannot touch another volume; it is
    //     enclosed by its own neighbors. Checking six neighbors is much cheaper than transforming
    //     the center into the other volume's space and inspecting its 3x3x3 neighborhood.
    const Vector3i macro_low(scan_low.x / MACRO_SIZE, scan_low.y / MACRO_SIZE, scan_low.z / MACRO_SIZE);
    const Vector3i macro_high((scan_high.x - 1) / MACRO_SIZE, (scan_high.y - 1) / MACRO_SIZE,
            (scan_high.z - 1) / MACRO_SIZE);
    for (int mz = macro_low.z; mz <= macro_high.z; ++mz) {
        for (int my = macro_low.y; my <= macro_high.y; ++my) {
            for (int mx = macro_low.x; mx <= macro_high.x; ++mx) {
                if (mx < 0 || my < 0 || mz < 0 || mx >= macro_dimensions.x ||
                        my >= macro_dimensions.y || mz >= macro_dimensions.z) {
                    continue;
                }
                if (macro_occupancy[macro_index_of(mx, my, mz)] == 0) {
                    continue;
                }
                const int z_end = std::min({scan_high.z, (mz + 1) * MACRO_SIZE, dimensions.z});
                const int y_end = std::min({scan_high.y, (my + 1) * MACRO_SIZE, dimensions.y});
                const int x_end = std::min({scan_high.x, (mx + 1) * MACRO_SIZE, dimensions.x});
                for (int z = std::max(scan_low.z, mz * MACRO_SIZE); z < z_end; ++z) {
                    for (int y = std::max(scan_low.y, my * MACRO_SIZE); y < y_end; ++y) {
                        for (int x = std::max(scan_low.x, mx * MACRO_SIZE); x < x_end; ++x) {
                            if (cells[index_of(x, y, z)] == AIR) {
                                continue;
                            }
                            if (x > 0 && y > 0 && z > 0 && x + 1 < dimensions.x &&
                                    y + 1 < dimensions.y && z + 1 < dimensions.z &&
                                    cells[index_of(x - 1, y, z)] != AIR &&
                                    cells[index_of(x + 1, y, z)] != AIR &&
                                    cells[index_of(x, y - 1, z)] != AIR &&
                                    cells[index_of(x, y + 1, z)] != AIR &&
                                    cells[index_of(x, y, z - 1)] != AIR &&
                                    cells[index_of(x, y, z + 1)] != AIR) {
                                continue;
                            }
                            if (--budget <= 0) {
                                return false;
                            }
                            const Vector3 local =
                                    (Vector3(x + 0.5, y + 0.5, z + 0.5) - self_half) *
                                    p_self_voxel_size;
                            const Vector3 in_other =
                                    self_to_other.xform(local) / p_other_voxel_size + other_half;
                            const Vector3i center(int(std::floor(in_other.x)),
                                    int(std::floor(in_other.y)), int(std::floor(in_other.z)));
                            for (int oz = center.z - reach; oz <= center.z + reach; ++oz) {
                                for (int oy = center.y - reach; oy <= center.y + reach; ++oy) {
                                    for (int ox = center.x - reach; ox <= center.x + reach; ++ox) {
                                        if (!other->in_bounds(ox, oy, oz)) {
                                            continue;
                                        }
                                        if (other->cells[other->index_of(ox, oy, oz)] != AIR) {
                                            return true;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    return false;
}

bool VoxelShapeData::component_touches(const PackedInt32Array &p_indices,
        const Ref<VoxelShapeData> &p_other, const Transform3D &p_other_to_self,
        double p_self_voxel_size, double p_other_voxel_size, double p_margin) const {
    if (p_other.is_null() || p_self_voxel_size <= 0.0 || p_other_voxel_size <= 0.0) {
        return false;
    }
    const VoxelShapeData *other = p_other.ptr();
    const Transform3D self_to_other = p_other_to_self.affine_inverse();
    const Vector3 self_half = Vector3(dimensions) * 0.5;
    const Vector3 other_half = Vector3(other->dimensions) * 0.5;
    const int reach = std::max(0, int(std::ceil(p_margin / p_other_voxel_size)));
    const int plane = dimensions.x * dimensions.y;
    // Most structural components are much larger than the neighbour they are tested against. The
    // previous loop transformed every voxel in a 300 K-voxel roof once per candidate Body even when
    // only a thin strip could overlap. Transform the other Shape's padded bounds once and reject
    // source voxels outside that conservative window before doing any matrix or occupancy work.
    const double padding = p_margin + std::max(p_self_voxel_size, p_other_voxel_size) * 1.5;
    const Vector3 other_extent = other_half * p_other_voxel_size + Vector3(padding, padding, padding);
    Vector3 scan_minimum(std::numeric_limits<double>::infinity(),
            std::numeric_limits<double>::infinity(), std::numeric_limits<double>::infinity());
    Vector3 scan_maximum = -scan_minimum;
    for (int corner = 0; corner < 8; ++corner) {
        const Vector3 other_local(
                (corner & 1) ? other_extent.x : -other_extent.x,
                (corner & 2) ? other_extent.y : -other_extent.y,
                (corner & 4) ? other_extent.z : -other_extent.z);
        const Vector3 self_voxel = p_other_to_self.xform(other_local) / p_self_voxel_size
                + self_half;
        scan_minimum = scan_minimum.min(self_voxel);
        scan_maximum = scan_maximum.max(self_voxel);
    }
    const Vector3i scan_low(
            std::max(0, static_cast<int>(std::floor(scan_minimum.x))),
            std::max(0, static_cast<int>(std::floor(scan_minimum.y))),
            std::max(0, static_cast<int>(std::floor(scan_minimum.z))));
    const Vector3i scan_high(
            std::min(dimensions.x - 1, static_cast<int>(std::ceil(scan_maximum.x))),
            std::min(dimensions.y - 1, static_cast<int>(std::ceil(scan_maximum.y))),
            std::min(dimensions.z - 1, static_cast<int>(std::ceil(scan_maximum.z))));
    for (int offset = 0; offset < p_indices.size(); ++offset) {
        const int index = p_indices[offset];
        if (index < 0 || index >= cells.size() || cells[index] == AIR) {
            continue;
        }
        const int z = index / plane;
        const int rest = index - z * plane;
        const int y = rest / dimensions.x;
        const int x = rest - y * dimensions.x;
        if (x < scan_low.x || y < scan_low.y || z < scan_low.z
                || x > scan_high.x || y > scan_high.y || z > scan_high.z) {
            continue;
        }
        const Vector3 local = (Vector3(x + 0.5, y + 0.5, z + 0.5) - self_half) *
                p_self_voxel_size;
        const Vector3 in_other = self_to_other.xform(local) / p_other_voxel_size + other_half;
        const Vector3i center(int(std::floor(in_other.x)), int(std::floor(in_other.y)),
                int(std::floor(in_other.z)));
        for (int oz = center.z - reach; oz <= center.z + reach; ++oz) {
            for (int oy = center.y - reach; oy <= center.y + reach; ++oy) {
                for (int ox = center.x - reach; ox <= center.x + reach; ++ox) {
                    if (other->in_bounds(ox, oy, oz) &&
                            other->cells[other->index_of(ox, oy, oz)] != AIR) {
                        return true;
                    }
                }
            }
        }
    }
    return false;
}

bool VoxelShapeData::component_seed_touches(int p_seed_index,
        const Ref<VoxelShapeData> &p_other, const Transform3D &p_other_to_self,
        double p_self_voxel_size, double p_other_voxel_size, double p_margin) const {
    if (p_other.is_null() || p_seed_index < 0 || p_seed_index >= cells.size()
            || cells[p_seed_index] == AIR || p_self_voxel_size <= 0.0
            || p_other_voxel_size <= 0.0) {
        return false;
    }
    if (connectivity_classification_revision != content_revision
            || connectivity_node_offsets.size() != macro_connectivity.size() + 1
            || connectivity_node_roots.empty()) {
        return component_touches(get_component_6(p_seed_index), p_other, p_other_to_self,
                p_self_voxel_size, p_other_voxel_size, p_margin);
    }
    const int plane = dimensions.x * dimensions.y;
    const int seed_z = p_seed_index / plane;
    const int seed_remaining = p_seed_index - seed_z * plane;
    const int seed_y = seed_remaining / dimensions.x;
    const int seed_x = seed_remaining - seed_y * dimensions.x;
    const int seed_macro = macro_index_of(seed_x / MACRO_SIZE,
            seed_y / MACRO_SIZE, seed_z / MACRO_SIZE);
    const int seed_local = (seed_x % MACRO_SIZE) + (seed_y % MACRO_SIZE) * MACRO_SIZE
            + (seed_z % MACRO_SIZE) * MACRO_SIZE * MACRO_SIZE;
    const uint16_t seed_label = macro_connectivity[
            static_cast<size_t>(seed_macro)].labels[static_cast<size_t>(seed_local)];
    if (seed_label == 0) return false;
    const int seed_node = connectivity_node_offsets[static_cast<size_t>(seed_macro)]
            + seed_label - 1;
    if (seed_node < 0 || static_cast<size_t>(seed_node) >= connectivity_node_roots.size()) {
        return false;
    }
    const int target_root = connectivity_node_roots[static_cast<size_t>(seed_node)];
    if (target_root < 0
            || static_cast<size_t>(target_root) >= connectivity_root_voxel_counts.size()
            || static_cast<size_t>(target_root) >= connectivity_root_members.size()) {
        return component_touches(get_component_6(p_seed_index), p_other, p_other_to_self,
                p_self_voxel_size, p_other_voxel_size, p_margin);
    }
    const VoxelShapeData *other = p_other.ptr();
    const Transform3D self_to_other = p_other_to_self.affine_inverse();
    const Vector3 self_half = Vector3(dimensions) * 0.5;
    const Vector3 other_half = Vector3(other->dimensions) * 0.5;
    const int reach = std::max(0, int(std::ceil(p_margin / p_other_voxel_size)));
    const int component_count = connectivity_root_voxel_counts[static_cast<size_t>(target_root)];
    // Scanning the other volume is only faster when it is substantially smaller. Choosing it for a
    // marginal size difference made a negative 166 K vs. 101 K query scan 101 K voxels and take
    // 20 ms in Lee; the path using this volume's root first prunes by overlapping macro-cells.
    if (static_cast<int64_t>(other->occupied_count) * 8 < component_count) {
        const int self_reach = std::max(0, int(std::ceil(p_margin / p_self_voxel_size)));
        for (int macro = 0; macro < other->macro_occupancy.size(); ++macro) {
            if (other->macro_occupancy[macro] == 0) continue;
            const int mz = macro / (other->macro_dimensions.x * other->macro_dimensions.y);
            const int rest = macro - mz * other->macro_dimensions.x * other->macro_dimensions.y;
            const int my = rest / other->macro_dimensions.x;
            const int mx = rest - my * other->macro_dimensions.x;
            for (int z = mz * MACRO_SIZE;
                    z < std::min((mz + 1) * MACRO_SIZE, other->dimensions.z); ++z) {
                for (int y = my * MACRO_SIZE;
                        y < std::min((my + 1) * MACRO_SIZE, other->dimensions.y); ++y) {
                    for (int x = mx * MACRO_SIZE;
                            x < std::min((mx + 1) * MACRO_SIZE, other->dimensions.x); ++x) {
                        if (other->cells[other->index_of(x, y, z)] == AIR) continue;
                        const Vector3 other_local =
                                (Vector3(x + 0.5, y + 0.5, z + 0.5) - other_half)
                                * p_other_voxel_size;
                        const Vector3 in_self = p_other_to_self.xform(other_local)
                                / p_self_voxel_size + self_half;
                        const Vector3i center(int(std::floor(in_self.x)),
                                int(std::floor(in_self.y)), int(std::floor(in_self.z)));
                        for (int sz = center.z - self_reach; sz <= center.z + self_reach; ++sz) {
                            for (int sy = center.y - self_reach; sy <= center.y + self_reach; ++sy) {
                                for (int sx = center.x - self_reach; sx <= center.x + self_reach; ++sx) {
                                    if (!in_bounds(sx, sy, sz)
                                            || cells[index_of(sx, sy, sz)] == AIR) continue;
                                    const int self_macro = macro_index_of(sx / MACRO_SIZE,
                                            sy / MACRO_SIZE, sz / MACRO_SIZE);
                                    const int self_local = (sx % MACRO_SIZE)
                                            + (sy % MACRO_SIZE) * MACRO_SIZE
                                            + (sz % MACRO_SIZE) * MACRO_SIZE * MACRO_SIZE;
                                    const uint16_t self_label = macro_connectivity[
                                            static_cast<size_t>(self_macro)].labels[
                                            static_cast<size_t>(self_local)];
                                    if (self_label == 0) continue;
                                    const int node = connectivity_node_offsets[
                                            static_cast<size_t>(self_macro)] + self_label - 1;
                                    if (connectivity_node_roots[static_cast<size_t>(node)]
                                            == target_root) {
                                        return true;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return false;
    }
    const double padding = p_margin + std::max(p_self_voxel_size, p_other_voxel_size) * 1.5;
    const Vector3 other_extent = other_half * p_other_voxel_size + Vector3(padding, padding, padding);
    Vector3 scan_minimum(std::numeric_limits<double>::infinity(),
            std::numeric_limits<double>::infinity(), std::numeric_limits<double>::infinity());
    Vector3 scan_maximum = -scan_minimum;
    for (int corner = 0; corner < 8; ++corner) {
        const Vector3 other_local(
                (corner & 1) ? other_extent.x : -other_extent.x,
                (corner & 2) ? other_extent.y : -other_extent.y,
                (corner & 4) ? other_extent.z : -other_extent.z);
        const Vector3 self_voxel = p_other_to_self.xform(other_local) / p_self_voxel_size
                + self_half;
        scan_minimum = scan_minimum.min(self_voxel);
        scan_maximum = scan_maximum.max(self_voxel);
    }
    const Vector3i scan_low(
            std::clamp(static_cast<int>(std::floor(scan_minimum.x)), 0, dimensions.x - 1),
            std::clamp(static_cast<int>(std::floor(scan_minimum.y)), 0, dimensions.y - 1),
            std::clamp(static_cast<int>(std::floor(scan_minimum.z)), 0, dimensions.z - 1));
    const Vector3i scan_high(
            std::clamp(static_cast<int>(std::ceil(scan_maximum.x)), scan_low.x, dimensions.x - 1),
            std::clamp(static_cast<int>(std::ceil(scan_maximum.y)), scan_low.y, dimensions.y - 1),
            std::clamp(static_cast<int>(std::ceil(scan_maximum.z)), scan_low.z, dimensions.z - 1));
    for (const uint64_t encoded : connectivity_root_members[static_cast<size_t>(target_root)]) {
        const size_t macro = static_cast<size_t>(encoded >> 32);
        const size_t label_index = static_cast<size_t>(encoded & 0xffffffffu);
        if (macro >= macro_connectivity.size()) continue;
        const MacroConnectivity &summary = macro_connectivity[macro];
        if (label_index >= summary.components.size()) continue;
        const int macro_z = static_cast<int>(macro)
                / (macro_dimensions.x * macro_dimensions.y);
        const int rest = static_cast<int>(macro)
                - macro_z * macro_dimensions.x * macro_dimensions.y;
        const int macro_y = rest / macro_dimensions.x;
        const int macro_x = rest - macro_y * macro_dimensions.x;
        const int x0 = macro_x * MACRO_SIZE;
        const int y0 = macro_y * MACRO_SIZE;
        const int z0 = macro_z * MACRO_SIZE;
        const int x1 = std::min(x0 + MACRO_SIZE, dimensions.x);
        const int y1 = std::min(y0 + MACRO_SIZE, dimensions.y);
        const int z1 = std::min(z0 + MACRO_SIZE, dimensions.z);
        Vector3 other_voxel_min(std::numeric_limits<double>::infinity(),
                std::numeric_limits<double>::infinity(), std::numeric_limits<double>::infinity());
        Vector3 other_voxel_max = -other_voxel_min;
        for (int corner = 0; corner < 8; ++corner) {
            const Vector3 self_local = (Vector3(
                    (corner & 1) ? x1 : x0,
                    (corner & 2) ? y1 : y0,
                    (corner & 4) ? z1 : z0) - self_half) * p_self_voxel_size;
            const Vector3 other_voxel = self_to_other.xform(self_local)
                    / p_other_voxel_size + other_half;
            other_voxel_min = other_voxel_min.min(other_voxel);
            other_voxel_max = other_voxel_max.max(other_voxel);
        }
        const int macro_padding = reach + 2;
        const Vector3i other_macro_low(
                std::clamp((static_cast<int>(std::floor(other_voxel_min.x)) - macro_padding)
                        / MACRO_SIZE, 0, other->macro_dimensions.x - 1),
                std::clamp((static_cast<int>(std::floor(other_voxel_min.y)) - macro_padding)
                        / MACRO_SIZE, 0, other->macro_dimensions.y - 1),
                std::clamp((static_cast<int>(std::floor(other_voxel_min.z)) - macro_padding)
                        / MACRO_SIZE, 0, other->macro_dimensions.z - 1));
        const Vector3i other_macro_high(
                std::clamp((static_cast<int>(std::ceil(other_voxel_max.x)) + macro_padding)
                        / MACRO_SIZE, 0, other->macro_dimensions.x - 1),
                std::clamp((static_cast<int>(std::ceil(other_voxel_max.y)) + macro_padding)
                        / MACRO_SIZE, 0, other->macro_dimensions.y - 1),
                std::clamp((static_cast<int>(std::ceil(other_voxel_max.z)) + macro_padding)
                        / MACRO_SIZE, 0, other->macro_dimensions.z - 1));
        bool potential_other = false;
        for (int omz = other_macro_low.z; omz <= other_macro_high.z && !potential_other; ++omz) {
            for (int omy = other_macro_low.y; omy <= other_macro_high.y && !potential_other; ++omy) {
                for (int omx = other_macro_low.x; omx <= other_macro_high.x; ++omx) {
                    if (other->macro_occupancy[other->macro_index_of(omx, omy, omz)] != 0) {
                        potential_other = true;
                        break;
                    }
                }
            }
        }
        if (!potential_other) continue;
        const LocalComponentSummary &component = summary.components[label_index];
        const Vector3i low = component.minimum.max(scan_low);
        const Vector3i high = component.maximum.min(scan_high);
        if (low.x > high.x || low.y > high.y || low.z > high.z) continue;
        const uint16_t wanted = static_cast<uint16_t>(label_index + 1);
        for (int z = low.z; z <= high.z; ++z) {
            for (int y = low.y; y <= high.y; ++y) {
                for (int x = low.x; x <= high.x; ++x) {
                    const int local = (x - x0) + (y - y0) * MACRO_SIZE
                            + (z - z0) * MACRO_SIZE * MACRO_SIZE;
                    if (summary.labels[static_cast<size_t>(local)] != wanted) continue;
                    const Vector3 local_position =
                            (Vector3(x + 0.5, y + 0.5, z + 0.5) - self_half)
                            * p_self_voxel_size;
                    const Vector3 in_other = self_to_other.xform(local_position)
                            / p_other_voxel_size + other_half;
                    const Vector3i center(int(std::floor(in_other.x)),
                            int(std::floor(in_other.y)), int(std::floor(in_other.z)));
                    for (int oz = center.z - reach; oz <= center.z + reach; ++oz) {
                        for (int oy = center.y - reach; oy <= center.y + reach; ++oy) {
                            for (int ox = center.x - reach; ox <= center.x + reach; ++ox) {
                                if (other->in_bounds(ox, oy, oz)
                                        && other->cells[other->index_of(ox, oy, oz)] != AIR) {
                                    return true;
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    return false;
}

PackedByteArray VoxelShapeData::rasterize_occupancy_region(const Transform3D &p_transform,
        double p_voxel_size, const Vector3i &p_world_low, const Vector3i &p_logical_size,
        double p_cell_size, const Vector3i &p_packed_size, const PackedByteArray &p_target) const {
    PackedByteArray result = p_target.duplicate();
    const int64_t expected_size = static_cast<int64_t>(p_packed_size.x) * p_packed_size.y * p_packed_size.z;
    if (p_voxel_size <= 0.0 || p_cell_size <= 0.0 || p_logical_size.x <= 0 ||
            p_logical_size.y <= 0 || p_logical_size.z <= 0 || expected_size != result.size()) {
        return result;
    }
    const Transform3D inverse = p_transform.affine_inverse();
    const Vector3 world_position = Vector3(p_world_low) * p_cell_size;
    const Vector3 world_size = Vector3(p_logical_size) * p_cell_size;
    Vector3 local_minimum(
            std::numeric_limits<double>::infinity(),
            std::numeric_limits<double>::infinity(),
            std::numeric_limits<double>::infinity());
    Vector3 local_maximum = -local_minimum;
    for (int corner = 0; corner < 8; ++corner) {
        const Vector3 world_corner = world_position + Vector3(
                (corner & 1) ? world_size.x : 0.0,
                (corner & 2) ? world_size.y : 0.0,
                (corner & 4) ? world_size.z : 0.0);
        const Vector3 local_voxel = inverse.xform(world_corner) / p_voxel_size + Vector3(dimensions) * 0.5;
        local_minimum = local_minimum.min(local_voxel);
        local_maximum = local_maximum.max(local_voxel);
    }
    const Vector3i voxel_low(
            std::clamp(static_cast<int>(std::floor(local_minimum.x)), 0, dimensions.x),
            std::clamp(static_cast<int>(std::floor(local_minimum.y)), 0, dimensions.y),
            std::clamp(static_cast<int>(std::floor(local_minimum.z)), 0, dimensions.z));
    const Vector3i voxel_high(
            std::clamp(static_cast<int>(std::ceil(local_maximum.x)), voxel_low.x, dimensions.x),
            std::clamp(static_cast<int>(std::ceil(local_maximum.y)), voxel_low.y, dimensions.y),
            std::clamp(static_cast<int>(std::ceil(local_maximum.z)), voxel_low.z, dimensions.z));
    uint8_t *write = result.ptrw();
    for (int z = voxel_low.z; z < voxel_high.z; ++z) {
        for (int y = voxel_low.y; y < voxel_high.y; ++y) {
            for (int x = voxel_low.x; x < voxel_high.x; ++x) {
                if (cells[index_of(x, y, z)] == AIR) {
                    continue;
                }
                const Vector3 local = (Vector3(x + 0.5, y + 0.5, z + 0.5) -
                                              Vector3(dimensions) * 0.5) *
                        p_voxel_size;
                const Vector3 world = p_transform.xform(local);
                const Vector3i world_cell(
                        static_cast<int>(std::floor(world.x / p_cell_size)),
                        static_cast<int>(std::floor(world.y / p_cell_size)),
                        static_cast<int>(std::floor(world.z / p_cell_size)));
                const Vector3i logical = world_cell - p_world_low;
                if (logical.x < 0 || logical.y < 0 || logical.z < 0 ||
                        logical.x >= p_logical_size.x || logical.y >= p_logical_size.y ||
                        logical.z >= p_logical_size.z) {
                    continue;
                }
                const Vector3i packed = logical / 2;
                const int bit = (logical.x & 1) | ((logical.y & 1) << 1) | ((logical.z & 1) << 2);
                const int target_index = packed.x + packed.y * p_packed_size.x +
                        packed.z * p_packed_size.x * p_packed_size.y;
                write[target_index] |= static_cast<uint8_t>(1u << bit);
            }
        }
    }
    return result;
}

// Fills an entire shadow-clipmap level at once. Previously, GDScript did this with a loop over
// every live voxel in every Shape and every level: Lee has 79.3 M x 4 = 317 M iterations at
// 1.58 M/s, or 201 seconds of startup with a black window. The existing per-Shape C++ version
// (`rasterize_occupancy_region`) is not suitable here because it duplicates the buffer's 16 MB on
// every call, and there are 2,312 Shapes per level.
//
// Three things make it inexpensive, in order of importance:
//
//  1. Bounds rejection. Each level covers 512 cells: 51.2 m at level 0 and 409.6 m at level 3. A
//     Shape outside the level's bounds is skipped without inspecting a voxel, and Shapes that do
//     overlap are cropped to the intersection.
//  2. Macrocells at coarse levels. When a level's cell is at least as large as a macrocell
//     (8 voxels), marking each occupied macrocell's footprint is enough instead of its 512 voxels.
//     This is conservative—it may enlarge the occluder by one cell—which is exactly what a mip is
//     meant to do.
//  3. Incremental traversal. Advancing one voxel along X adds a constant to the world position, so
//     a full `xform` is not needed for every voxel.
PackedByteArray VoxelShapeData::rasterize_occupancy_level(const TypedArray<VoxelShapeData> &p_shapes,
        const TypedArray<Transform3D> &p_transforms, const PackedFloat32Array &p_voxel_sizes,
        const Vector3i &p_world_low, const Vector3i &p_logical_size, double p_cell_size,
        const Vector3i &p_packed_size) {
    PackedByteArray result;
    const int64_t expected_size = static_cast<int64_t>(p_packed_size.x) * p_packed_size.y * p_packed_size.z;
    if (expected_size <= 0 || p_cell_size <= 0.0 || p_logical_size.x <= 0 ||
            p_logical_size.y <= 0 || p_logical_size.z <= 0) {
        return result;
    }
    const int shape_count = p_shapes.size();
    if (shape_count != p_transforms.size() || shape_count != p_voxel_sizes.size()) {
        return result;
    }
    result.resize(static_cast<int>(expected_size));
    result.fill(0);
    uint8_t *write = result.ptrw();

    const Vector3 level_low = Vector3(p_world_low) * p_cell_size;
    const Vector3 level_high = level_low + Vector3(p_logical_size) * p_cell_size;

    // Level cell relative to its origin for a world position.
    const auto cell_of = [&](const Vector3 &world) {
        return Vector3i(
                static_cast<int>(std::floor(world.x / p_cell_size)) - p_world_low.x,
                static_cast<int>(std::floor(world.y / p_cell_size)) - p_world_low.y,
                static_cast<int>(std::floor(world.z / p_cell_size)) - p_world_low.z);
    };
    // Marks a cell. Returns without changing anything if it is outside the level.
    const auto mark = [&](const Vector3i &cell) {
        if (cell.x < 0 || cell.y < 0 || cell.z < 0 || cell.x >= p_logical_size.x ||
                cell.y >= p_logical_size.y || cell.z >= p_logical_size.z) {
            return;
        }
        const int bit = (cell.x & 1) | ((cell.y & 1) << 1) | ((cell.z & 1) << 2);
        const int index = (cell.x >> 1) + (cell.y >> 1) * p_packed_size.x +
                (cell.z >> 1) * p_packed_size.x * p_packed_size.y;
        write[index] |= static_cast<uint8_t>(1u << bit);
    };

    for (int shape_index = 0; shape_index < shape_count; ++shape_index) {
        Ref<VoxelShapeData> shape = p_shapes[shape_index];
        if (shape.is_null() || shape->occupied_count == 0) {
            continue;
        }
        const Transform3D transform = p_transforms[shape_index];
        const double voxel_size = p_voxel_sizes[shape_index];
        if (voxel_size <= 0.0) {
            continue;
        }
        const Vector3i shape_dimensions = shape->dimensions;
        const Vector3 half = Vector3(shape_dimensions) * 0.5;

        // Crop to the overlap with the level bounds, in this Shape's voxel coordinates. Transform
        // all eight box corners into local space because the Shape may be rotated.
        const Transform3D inverse = transform.affine_inverse();
        Vector3 local_minimum(std::numeric_limits<double>::infinity(),
                std::numeric_limits<double>::infinity(), std::numeric_limits<double>::infinity());
        Vector3 local_maximum = -local_minimum;
        for (int corner = 0; corner < 8; ++corner) {
            const Vector3 world_corner(
                    (corner & 1) ? level_high.x : level_low.x,
                    (corner & 2) ? level_high.y : level_low.y,
                    (corner & 4) ? level_high.z : level_low.z);
            const Vector3 local_voxel = inverse.xform(world_corner) / voxel_size + half;
            local_minimum = local_minimum.min(local_voxel);
            local_maximum = local_maximum.max(local_voxel);
        }
        // The one-voxel margin is not paranoia: cropping transforms the level bounds into local
        // space with the inverse transform, while marking transforms voxels into world space with
        // the forward transform. In floating point these can differ by a few bits, so a voxel
        // exactly on the edge could be cropped out and its cell lost. Without the margin, the test
        // found seven missing cells at level 2 in the Lee crop.
        const Vector3i voxel_low(
                std::clamp(static_cast<int>(std::floor(local_minimum.x)) - 1, 0, shape_dimensions.x),
                std::clamp(static_cast<int>(std::floor(local_minimum.y)) - 1, 0, shape_dimensions.y),
                std::clamp(static_cast<int>(std::floor(local_minimum.z)) - 1, 0, shape_dimensions.z));
        const Vector3i voxel_high(
                std::clamp(static_cast<int>(std::ceil(local_maximum.x)) + 1, voxel_low.x, shape_dimensions.x),
                std::clamp(static_cast<int>(std::ceil(local_maximum.y)) + 1, voxel_low.y, shape_dimensions.y),
                std::clamp(static_cast<int>(std::ceil(local_maximum.z)) + 1, voxel_low.z, shape_dimensions.z));
        if (voxel_low.x >= voxel_high.x || voxel_low.y >= voxel_high.y || voxel_low.z >= voxel_high.z) {
            continue;
        }

        if (p_cell_size >= MACRO_SIZE * voxel_size) {
            // Coarse level: a macrocell fits in one cell, so mark its footprint and skip its 512
            // voxels. Level 3 uses 0.8 m cells, exactly the size of eight 0.1 m voxels in a
            // macrocell.
            const Vector3i macro_low(voxel_low.x / MACRO_SIZE, voxel_low.y / MACRO_SIZE, voxel_low.z / MACRO_SIZE);
            const Vector3i macro_high((voxel_high.x + MACRO_SIZE - 1) / MACRO_SIZE,
                    (voxel_high.y + MACRO_SIZE - 1) / MACRO_SIZE,
                    (voxel_high.z + MACRO_SIZE - 1) / MACRO_SIZE);
            const uint8_t *macros = shape->macro_occupancy.ptr();
            for (int mz = macro_low.z; mz < macro_high.z && mz < shape->macro_dimensions.z; ++mz) {
                for (int my = macro_low.y; my < macro_high.y && my < shape->macro_dimensions.y; ++my) {
                    for (int mx = macro_low.x; mx < macro_high.x && mx < shape->macro_dimensions.x; ++mx) {
                        if (macros[shape->macro_index_of(mx, my, mz)] == 0) {
                            continue;
                        }
                        // Macrocell footprint: transform its eight corners into world space, then
                        // mark every cell in their bounding box. An unrotated Shape covers one or
                        // two cells per axis; a rotated one may cover more, always enough.
                        const Vector3 base = (Vector3(mx, my, mz) * MACRO_SIZE - half) * voxel_size;
                        Vector3 world_minimum(std::numeric_limits<double>::infinity(),
                                std::numeric_limits<double>::infinity(),
                                std::numeric_limits<double>::infinity());
                        Vector3 world_maximum = -world_minimum;
                        for (int corner = 0; corner < 8; ++corner) {
                            const Vector3 offset(
                                    (corner & 1) ? MACRO_SIZE * voxel_size : 0.0,
                                    (corner & 2) ? MACRO_SIZE * voxel_size : 0.0,
                                    (corner & 4) ? MACRO_SIZE * voxel_size : 0.0);
                            const Vector3 world = transform.xform(base + offset);
                            world_minimum = world_minimum.min(world);
                            world_maximum = world_maximum.max(world);
                        }
                        const Vector3i cell_low = cell_of(world_minimum);
                        const Vector3i cell_high = cell_of(world_maximum);
                        for (int cz = cell_low.z; cz <= cell_high.z; ++cz) {
                            for (int cy = cell_low.y; cy <= cell_high.y; ++cy) {
                                for (int cx = cell_low.x; cx <= cell_high.x; ++cx) {
                                    mark(Vector3i(cx, cy, cz));
                                }
                            }
                        }
                    }
                }
            }
            continue;
        }

        // Each voxel is transformed into world space with its complete `xform`. Starting at the
        // corner and adding incremental steps is faster but not bit-identical:
        // `xform(a) + B*d` and `xform(a + d)` round differently, and truncation can move a voxel
        // less than a millionth of a cell edge into another cell. In Lee's crop, that lost seven
        // cells at level 2.
        const uint8_t *voxels = shape->cells.ptr();
        for (int z = voxel_low.z; z < voxel_high.z; ++z) {
            for (int y = voxel_low.y; y < voxel_high.y; ++y) {
                const int row_base = y * shape_dimensions.x +
                        z * shape_dimensions.x * shape_dimensions.y;
                for (int x = voxel_low.x; x < voxel_high.x; ++x) {
                    if (voxels[row_base + x] == AIR) {
                        continue;
                    }
                    const Vector3 local = (Vector3(x + 0.5, y + 0.5, z + 0.5) - half) * voxel_size;
                    mark(cell_of(transform.xform(local)));
                }
            }
        }
    }
    return result;
}

// `p_block` groups several macrocells into one collision mesh. A value of 1 produces a mesh per
// 8-voxel macrocell, suitable for a wall that takes impacts; a value of 4 produces one per
// 32 voxels (3.2 m), requiring 64 times fewer concave shapes. On a Teardown map, that difference
// is 13,000 shapes and four seconds for every 380,000 loaded voxels.
PackedVector3Array VoxelShapeData::build_macro_faces(
        const Vector3i &p_macro, double p_voxel_size, int p_block, int p_lod,
        const PackedByteArray &p_collidable) const {
    PackedVector3Array faces;
    const int block = std::max(1, p_block);
    const int lod = std::clamp(p_lod, 1, 4);
    if (p_voxel_size <= 0.0 || p_macro.x < 0 || p_macro.y < 0 || p_macro.z < 0 ||
            p_macro.x * block >= macro_dimensions.x || p_macro.y * block >= macro_dimensions.y ||
            p_macro.z * block >= macro_dimensions.z) {
        return faces;
    }
    const int span = MACRO_SIZE * block;
    Vector3i low = p_macro * span;
    Vector3i high(
            std::min(low.x + span, dimensions.x),
            std::min(low.y + span, dimensions.y),
            std::min(low.z + span, dimensions.z));

    // A block groups up to 4x4x4 macrocells, and the scan used to traverse its entire volume—32^3
    // cells along each of the six axes—even when it contained only a floor slab. Crop to the bounds
    // of macrocells containing data, then skip each empty macrocell within those bounds, because
    // every cell in an empty macrocell is air and cannot produce a face. Without this, generating
    // faces alone took 24.5 s for the entire map.
    const uint8_t *occupancy = macro_occupancy.ptr();
    const Vector3i macro_low = p_macro * block;
    const Vector3i macro_high(
            std::min(macro_low.x + block, macro_dimensions.x),
            std::min(macro_low.y + block, macro_dimensions.y),
            std::min(macro_low.z + block, macro_dimensions.z));
    Vector3i used_low(macro_high.x, macro_high.y, macro_high.z);
    Vector3i used_high(macro_low.x - 1, macro_low.y - 1, macro_low.z - 1);
    for (int mz = macro_low.z; mz < macro_high.z; ++mz) {
        for (int my = macro_low.y; my < macro_high.y; ++my) {
            for (int mx = macro_low.x; mx < macro_high.x; ++mx) {
                if (occupancy[macro_index_of(mx, my, mz)] == 0) {
                    continue;
                }
                used_low = Vector3i(std::min(used_low.x, mx), std::min(used_low.y, my),
                        std::min(used_low.z, mz));
                used_high = Vector3i(std::max(used_high.x, mx), std::max(used_high.y, my),
                        std::max(used_high.z, mz));
            }
        }
    }
    if (used_high.x < used_low.x) {
        return faces;
    }
    low = Vector3i(std::max(low.x, used_low.x * MACRO_SIZE), std::max(low.y, used_low.y * MACRO_SIZE),
            std::max(low.z, used_low.z * MACRO_SIZE));
    high = Vector3i(std::min(high.x, (used_high.x + 1) * MACRO_SIZE),
            std::min(high.y, (used_high.y + 1) * MACRO_SIZE),
            std::min(high.z, (used_high.z + 1) * MACRO_SIZE));
    const auto macro_empty = [&](int x, int y, int z) {
        return occupancy[macro_index_of(x / MACRO_SIZE, y / MACRO_SIZE, z / MACRO_SIZE)] == 0;
    };

    const Vector3 half_dimensions = Vector3(dimensions) * 0.5;
    // `cells[i]` in godot-cpp is not a memory access: it calls
    // `packed_byte_array_operator_index_const` through the GDExtension interface, which cannot be
    // inlined. This lambda is called twice per cell in every block and six times per axis, adding
    // billions of calls on the full map and 29.7 s to collision-face generation.
    const uint8_t *voxels = cells.ptr();
    // One entry per palette index: 0 means the player passes through it. Teardown marks foliage
    // this way with its `unphysical` material; these voxels count as air here—they are still
    // rendered and destructible, but are omitted from the mesh sent to Jolt. Empty means all
    // materials collide.
    const uint8_t *collidable = p_collidable.size() == 256 ? p_collidable.ptr() : nullptr;
    const auto coarse_occupied = [&](int x0, int y0, int z0) {
        if (x0 < 0 || y0 < 0 || z0 < 0 ||
                x0 >= dimensions.x || y0 >= dimensions.y || z0 >= dimensions.z) {
            return false;
        }
        for (int z = z0; z < std::min(z0 + lod, dimensions.z); ++z) {
            for (int y = y0; y < std::min(y0 + lod, dimensions.y); ++y) {
                for (int x = x0; x < std::min(x0 + lod, dimensions.x); ++x) {
                    const uint8_t cell = voxels[index_of(x, y, z)];
                    if (cell != AIR && (collidable == nullptr || collidable[cell] != 0)) {
                        return true;
                    }
                }
            }
        }
        return false;
    };
    const auto world_point = [&](int x, int y, int z) {
        return (Vector3(x, y, z) - half_dimensions) * p_voxel_size;
    };
    // `faces.append()` is another call through the GDExtension interface. The full map has
    // 216 M vertices, which means 216 M calls and reallocations; collect them in a regular vector
    // and transfer them all at once at the end.
    std::vector<Vector3> collected;
    const auto append_quad = [&](const Vector3 &a, const Vector3 &b,
                                 const Vector3 &c, const Vector3 &d) {
        collected.push_back(a);
        collected.push_back(b);
        collected.push_back(c);
        collected.push_back(a);
        collected.push_back(c);
        collected.push_back(d);
    };

    // Greedy-merge exposed coplanar cells per slice. This keeps the exact 10 cm collision surface
    // at LOD 1, but a 64x64 wall becomes two triangles instead of 8192. Jolt then builds a much
    // smaller acceleration structure without the inflated ground that coarse occupancy caused.
    for (int face = 0; face < 6; ++face) {
        const int axis = face / 2;
        const int sign = (face % 2 == 0) ? 1 : -1;
        const int slice_low = axis == 0 ? low.x : (axis == 1 ? low.y : low.z);
        const int slice_high = axis == 0 ? high.x : (axis == 1 ? high.y : high.z);
        const int u_low = axis == 0 ? low.y : low.x;
        const int u_high = axis == 0 ? high.y : high.x;
        const int v_low = axis == 2 ? low.y : low.z;
        const int v_high = axis == 2 ? high.y : high.z;
        const int u_count = (u_high - u_low + lod - 1) / lod;
        const int v_count = (v_high - v_low + lod - 1) / lod;
        std::vector<uint8_t> mask(static_cast<size_t>(u_count * v_count), 0);

        for (int slice = slice_low; slice < slice_high; slice += lod) {
            std::fill(mask.begin(), mask.end(), 0);
            for (int v = 0; v < v_count; ++v) {
                for (int u = 0; u < u_count; ++u) {
                    int x;
                    int y;
                    int z;
                    if (axis == 0) {
                        x = slice;
                        y = u_low + u * lod;
                        z = v_low + v * lod;
                    } else if (axis == 1) {
                        x = u_low + u * lod;
                        y = slice;
                        z = v_low + v * lod;
                    } else {
                        x = u_low + u * lod;
                        y = v_low + v * lod;
                        z = slice;
                    }
                    if (macro_empty(x, y, z)) {
                        // The entire macro-cell is air: skip to its edge instead of checking its
                        // eight cells one by one.
                        // Round down: with LOD > 1, rounding up could cross the edge and skip
                        // cells that may contain a face.
                        const int cell_u = axis == 0 ? y : x;
                        u += std::max(1, (MACRO_SIZE - cell_u % MACRO_SIZE) / lod) - 1;
                        continue;
                    }
                    if (!coarse_occupied(x, y, z)) {
                        continue;
                    }
                    const int nx = x + (axis == 0 ? sign * lod : 0);
                    const int ny = y + (axis == 1 ? sign * lod : 0);
                    const int nz = z + (axis == 2 ? sign * lod : 0);
                    if (!coarse_occupied(nx, ny, nz)) {
                        mask[static_cast<size_t>(u + v * u_count)] = 1;
                    }
                }
            }

            for (int v = 0; v < v_count; ++v) {
                for (int u = 0; u < u_count;) {
                    if (mask[static_cast<size_t>(u + v * u_count)] == 0) {
                        ++u;
                        continue;
                    }
                    int width = 1;
                    while (u + width < u_count
                            && mask[static_cast<size_t>(u + width + v * u_count)] != 0) {
                        ++width;
                    }
                    int height = 1;
                    bool can_grow = true;
                    while (v + height < v_count && can_grow) {
                        for (int offset = 0; offset < width; ++offset) {
                            if (mask[static_cast<size_t>(u + offset
                                            + (v + height) * u_count)] == 0) {
                                can_grow = false;
                                break;
                            }
                        }
                        if (can_grow) {
                            ++height;
                        }
                    }
                    for (int dv = 0; dv < height; ++dv) {
                        for (int du = 0; du < width; ++du) {
                            mask[static_cast<size_t>(u + du + (v + dv) * u_count)] = 0;
                        }
                    }

                    const int u0 = u_low + u * lod;
                    const int u1 = std::min(u_low + (u + width) * lod, u_high);
                    const int v0 = v_low + v * lod;
                    const int v1 = std::min(v_low + (v + height) * lod, v_high);
                    const int plane = sign > 0 ? std::min(slice + lod,
                            axis == 0 ? dimensions.x : (axis == 1 ? dimensions.y : dimensions.z))
                            : slice;
                    Vector3 a;
                    Vector3 b;
                    Vector3 c;
                    Vector3 d;
                    if (axis == 0 && sign > 0) {
                        a = world_point(plane, u0, v0); b = world_point(plane, u1, v0);
                        c = world_point(plane, u1, v1); d = world_point(plane, u0, v1);
                    } else if (axis == 0) {
                        a = world_point(plane, u0, v1); b = world_point(plane, u1, v1);
                        c = world_point(plane, u1, v0); d = world_point(plane, u0, v0);
                    } else if (axis == 1 && sign > 0) {
                        a = world_point(u0, plane, v1); b = world_point(u1, plane, v1);
                        c = world_point(u1, plane, v0); d = world_point(u0, plane, v0);
                    } else if (axis == 1) {
                        a = world_point(u0, plane, v0); b = world_point(u1, plane, v0);
                        c = world_point(u1, plane, v1); d = world_point(u0, plane, v1);
                    } else if (sign > 0) {
                        a = world_point(u1, v0, plane); b = world_point(u1, v1, plane);
                        c = world_point(u0, v1, plane); d = world_point(u0, v0, plane);
                    } else {
                        a = world_point(u0, v0, plane); b = world_point(u0, v1, plane);
                        c = world_point(u1, v1, plane); d = world_point(u1, v0, plane);
                    }
                    append_quad(a, b, c, d);
                    u += width;
                }
            }
        }
    }
    faces.resize(static_cast<int64_t>(collected.size()));
    if (!collected.empty()) {
        memcpy(faces.ptrw(), collected.data(), collected.size() * sizeof(Vector3));
    }
    return faces;
}

void VoxelShapeData::rebuild_macrocell(int mx, int my, int mz, bool p_rebuild_adjacency) {
    if (mx < 0 || my < 0 || mz < 0 ||
            mx >= macro_dimensions.x || my >= macro_dimensions.y || mz >= macro_dimensions.z) {
        return;
    }
    const int x0 = mx * MACRO_SIZE;
    const int y0 = my * MACRO_SIZE;
    const int z0 = mz * MACRO_SIZE;
    uint8_t occupied = 0;
    for (int z = z0; z < std::min(z0 + MACRO_SIZE, dimensions.z) && occupied == 0; ++z) {
        for (int y = y0; y < std::min(y0 + MACRO_SIZE, dimensions.y) && occupied == 0; ++y) {
            for (int x = x0; x < std::min(x0 + MACRO_SIZE, dimensions.x); ++x) {
                if (cells[index_of(x, y, z)] != AIR) {
                    occupied = 1;
                    break;
                }
            }
        }
    }
    macro_occupancy.set(macro_index_of(mx, my, mz), occupied);
    if (!connectivity_index_built) {
        return;
    }
    rebuild_macro_connectivity(mx, my, mz);
    if (!p_rebuild_adjacency) {
        return;
    }
    rebuild_macro_adjacency(mx, my, mz);
    rebuild_macro_adjacency(mx - 1, my, mz);
    rebuild_macro_adjacency(mx + 1, my, mz);
    rebuild_macro_adjacency(mx, my - 1, mz);
    rebuild_macro_adjacency(mx, my + 1, mz);
    rebuild_macro_adjacency(mx, my, mz - 1);
    rebuild_macro_adjacency(mx, my, mz + 1);
}

void VoxelShapeData::rebuild_macro_connectivity(int mx, int my, int mz) {
    if (mx < 0 || my < 0 || mz < 0 || mx >= macro_dimensions.x
            || my >= macro_dimensions.y || mz >= macro_dimensions.z) {
        return;
    }
    const int macro_index = macro_index_of(mx, my, mz);
    if (macro_index < 0 || static_cast<size_t>(macro_index) >= macro_connectivity.size()) {
        return;
    }
    MacroConnectivity &summary = macro_connectivity[static_cast<size_t>(macro_index)];
    summary.labels.assign(MACRO_SIZE * MACRO_SIZE * MACRO_SIZE, 0);
    summary.components.clear();
    summary.external_neighbours.clear();
    if (macro_occupancy[macro_index] == 0) {
        return;
    }

    const int x0 = mx * MACRO_SIZE;
    const int y0 = my * MACRO_SIZE;
    const int z0 = mz * MACRO_SIZE;
    const int x1 = std::min(x0 + MACRO_SIZE, dimensions.x);
    const int y1 = std::min(y0 + MACRO_SIZE, dimensions.y);
    const int z1 = std::min(z0 + MACRO_SIZE, dimensions.z);
    const auto local_index = [&](int x, int y, int z) {
        return (x - x0) + (y - y0) * MACRO_SIZE + (z - z0) * MACRO_SIZE * MACRO_SIZE;
    };
    std::vector<Vector3i> queue;
    queue.reserve(MACRO_SIZE * MACRO_SIZE * MACRO_SIZE);
    for (int z = z0; z < z1; ++z) {
        for (int y = y0; y < y1; ++y) {
            for (int x = x0; x < x1; ++x) {
                const int local = local_index(x, y, z);
                if (cells[index_of(x, y, z)] == AIR || summary.labels[local] != 0) {
                    continue;
                }
                summary.components.emplace_back();
                LocalComponentSummary &component = summary.components.back();
                component.minimum = Vector3i(x, y, z);
                component.maximum = component.minimum;
                component.seed_index = index_of(x, y, z);
                const uint16_t label = static_cast<uint16_t>(summary.components.size());
                queue.clear();
                queue.push_back(Vector3i(x, y, z));
                summary.labels[local] = label;
                size_t cursor = 0;
                while (cursor < queue.size()) {
                    const Vector3i cell = queue[cursor++];
                    ++component.count;
                    component.minimum = component.minimum.min(cell);
                    component.maximum = component.maximum.max(cell);
                    ++component.layer_counts[static_cast<size_t>(cell.y - y0)];
                    const uint8_t material = cells[index_of(cell.x, cell.y, cell.z)];
                    const uint8_t local_y = static_cast<uint8_t>(cell.y - y0);
                    auto material_layer = std::find_if(component.material_layers.begin(),
                            component.material_layers.end(),
                            [&](const MaterialLayerCount &entry) {
                                return entry.material == material && entry.local_y == local_y;
                            });
                    if (material_layer == component.material_layers.end()) {
                        component.material_layers.push_back({material, local_y, 1});
                    } else {
                        ++material_layer->count;
                    }
                    const Vector3i directions[6] = {
                        Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
                        Vector3i(0, 1, 0), Vector3i(0, -1, 0),
                        Vector3i(0, 0, 1), Vector3i(0, 0, -1),
                    };
                    for (const Vector3i &direction : directions) {
                        const Vector3i next = cell + direction;
                        if (next.x < x0 || next.y < y0 || next.z < z0
                                || next.x >= x1 || next.y >= y1 || next.z >= z1) {
                            continue;
                        }
                        const int next_local = local_index(next.x, next.y, next.z);
                        if (summary.labels[next_local] != 0
                                || cells[index_of(next.x, next.y, next.z)] == AIR) {
                            continue;
                        }
                        summary.labels[next_local] = label;
                        queue.push_back(next);
                    }
                }
            }
        }
    }
}

void VoxelShapeData::rebuild_macro_adjacency(int mx, int my, int mz) {
    if (mx < 0 || my < 0 || mz < 0 || mx >= macro_dimensions.x
            || my >= macro_dimensions.y || mz >= macro_dimensions.z) {
        return;
    }
    const int macro_index = macro_index_of(mx, my, mz);
    MacroConnectivity &summary = macro_connectivity[static_cast<size_t>(macro_index)];
    summary.external_neighbours.clear();
    summary.external_neighbours.resize(summary.components.size());
    if (summary.components.empty()) {
        return;
    }
    const int x0 = mx * MACRO_SIZE;
    const int y0 = my * MACRO_SIZE;
    const int z0 = mz * MACRO_SIZE;
    const int x1 = std::min(x0 + MACRO_SIZE, dimensions.x);
    const int y1 = std::min(y0 + MACRO_SIZE, dimensions.y);
    const int z1 = std::min(z0 + MACRO_SIZE, dimensions.z);
    const Vector3i directions[6] = {
        Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
        Vector3i(0, 1, 0), Vector3i(0, -1, 0),
        Vector3i(0, 0, 1), Vector3i(0, 0, -1),
    };
    for (int z = z0; z < z1; ++z) {
        for (int y = y0; y < y1; ++y) {
            for (int x = x0; x < x1; ++x) {
                if (cells[index_of(x, y, z)] == AIR) continue;
                const int local = (x - x0) + (y - y0) * MACRO_SIZE
                        + (z - z0) * MACRO_SIZE * MACRO_SIZE;
                const uint16_t label = summary.labels[static_cast<size_t>(local)];
                if (label == 0) continue;
                for (const Vector3i &direction : directions) {
                    const Vector3i next = Vector3i(x, y, z) + direction;
                    if (!in_bounds(next.x, next.y, next.z)
                            || (next.x >= x0 && next.x < x1 && next.y >= y0 && next.y < y1
                                    && next.z >= z0 && next.z < z1)
                            || cells[index_of(next.x, next.y, next.z)] == AIR) {
                        continue;
                    }
                    const int neighbour_mx = next.x / MACRO_SIZE;
                    const int neighbour_my = next.y / MACRO_SIZE;
                    const int neighbour_mz = next.z / MACRO_SIZE;
                    const int neighbour_macro = macro_index_of(
                            neighbour_mx, neighbour_my, neighbour_mz);
                    const MacroConnectivity &neighbour =
                            macro_connectivity[static_cast<size_t>(neighbour_macro)];
                    if (neighbour.labels.empty()) continue;
                    const int neighbour_local = (next.x % MACRO_SIZE)
                            + (next.y % MACRO_SIZE) * MACRO_SIZE
                            + (next.z % MACRO_SIZE) * MACRO_SIZE * MACRO_SIZE;
                    const uint16_t neighbour_label =
                            neighbour.labels[static_cast<size_t>(neighbour_local)];
                    if (neighbour_label == 0) continue;
                    const uint64_t encoded = (static_cast<uint64_t>(neighbour_macro) << 16)
                            | static_cast<uint64_t>(neighbour_label);
                    std::vector<uint64_t> &edges =
                            summary.external_neighbours[static_cast<size_t>(label - 1)];
                    if (std::find(edges.begin(), edges.end(), encoded) == edges.end()) {
                        edges.push_back(encoded);
                    }
                }
            }
        }
    }
}

void VoxelShapeData::rebuild_macrocells() {
    const bool rebuild_index = connectivity_index_built;
    connectivity_index_built = false;
    for (int z = 0; z < macro_dimensions.z; ++z) {
        for (int y = 0; y < macro_dimensions.y; ++y) {
            for (int x = 0; x < macro_dimensions.x; ++x) {
                rebuild_macrocell(x, y, z, false);
            }
        }
    }
    if (rebuild_index) {
        rebuild_connectivity_index();
    }
}

void VoxelShapeData::rebuild_connectivity_index() {
    macro_connectivity.clear();
    macro_connectivity.resize(static_cast<size_t>(macro_occupancy.size()));
    for (int z = 0; z < macro_dimensions.z; ++z) {
        for (int y = 0; y < macro_dimensions.y; ++y) {
            for (int x = 0; x < macro_dimensions.x; ++x) {
                if (macro_occupancy[macro_index_of(x, y, z)] != 0) {
                    rebuild_macro_connectivity(x, y, z);
                }
            }
        }
    }
    for (int z = 0; z < macro_dimensions.z; ++z) {
        for (int y = 0; y < macro_dimensions.y; ++y) {
            for (int x = 0; x < macro_dimensions.x; ++x) {
                if (!macro_connectivity[static_cast<size_t>(macro_index_of(x, y, z))]
                        .components.empty()) {
                    rebuild_macro_adjacency(x, y, z);
                }
            }
        }
    }
    connectivity_index_built = true;
}

Dictionary VoxelShapeData::damage_sphere(
        const Vector3 &p_center_voxels, double p_radius_voxels, double p_energy) {
    Dictionary result;
    PackedInt32Array removed_indices;
    PackedByteArray removed_materials;
    result["removed"] = 0;
    result["dirty_min"] = Vector3i(-1, -1, -1);
    result["dirty_max"] = Vector3i(-1, -1, -1);
    result["bytes_touched"] = 0;
    result["removed_indices"] = removed_indices;
    result["removed_materials"] = removed_materials;
    if (cells.is_empty() || p_radius_voxels <= 0.0 || p_energy <= 0.0) {
        return result;
    }

    const double effective_radius = p_radius_voxels * std::sqrt(p_energy);
    const double radius_squared = effective_radius * effective_radius;
    const Vector3i low(
            std::max(0, static_cast<int>(std::floor(p_center_voxels.x - effective_radius))),
            std::max(0, static_cast<int>(std::floor(p_center_voxels.y - effective_radius))),
            std::max(0, static_cast<int>(std::floor(p_center_voxels.z - effective_radius))));
    const Vector3i high(
            std::min(dimensions.x - 1, static_cast<int>(std::ceil(p_center_voxels.x + effective_radius))),
            std::min(dimensions.y - 1, static_cast<int>(std::ceil(p_center_voxels.y + effective_radius))),
            std::min(dimensions.z - 1, static_cast<int>(std::ceil(p_center_voxels.z + effective_radius))));

    Vector3i dirty_min(dimensions.x, dimensions.y, dimensions.z);
    Vector3i dirty_max(-1, -1, -1);
    int removed = 0;
    uint8_t *write = cells.ptrw();
    for (int z = low.z; z <= high.z; ++z) {
        for (int y = low.y; y <= high.y; ++y) {
            for (int x = low.x; x <= high.x; ++x) {
                const Vector3 delta = Vector3(x + 0.5, y + 0.5, z + 0.5) - p_center_voxels;
                if (delta.length_squared() > radius_squared) {
                    continue;
                }
                const int index = index_of(x, y, z);
                if (write[index] == AIR) {
                    continue;
                }
                const uint8_t material = write[index];
                write[index] = AIR;
                --occupied_count;
                --material_counts[material];
                ++removed;
                reservoir_damage_sample(
                        removed_indices, removed_materials, index, material, removed);
                dirty_min = dirty_min.min(Vector3i(x, y, z));
                dirty_max = dirty_max.max(Vector3i(x, y, z));
            }
        }
    }

    if (removed > 0) {
        const Vector3i macro_low = dirty_min / MACRO_SIZE;
        const Vector3i macro_high = dirty_max / MACRO_SIZE;
        for (int z = macro_low.z; z <= macro_high.z; ++z) {
            for (int y = macro_low.y; y <= macro_high.y; ++y) {
                for (int x = macro_low.x; x <= macro_high.x; ++x) {
                    rebuild_macrocell(x, y, z);
                }
            }
        }
        const Vector3i dirty_size = dirty_max - dirty_min + Vector3i(1, 1, 1);
        result["dirty_min"] = dirty_min;
        result["dirty_max"] = dirty_max;
        result["bytes_touched"] = dirty_size.x * dirty_size.y * dirty_size.z;
        ++content_revision;
    }
    result["removed"] = removed;
    result["removed_indices"] = removed_indices;
    result["removed_materials"] = removed_materials;
    return result;
}

Dictionary VoxelShapeData::damage_sphere_material(const Vector3 &p_center_voxels,
        double p_radius_voxels, double p_energy, const PackedFloat32Array &p_hardnesses,
        double p_foundation_threshold) {
    Dictionary result;
    PackedInt32Array removed_indices;
    PackedByteArray removed_materials;
    result["removed"] = 0;
    result["removed_foundation"] = 0;
    result["dirty_min"] = Vector3i(-1, -1, -1);
    result["dirty_max"] = Vector3i(-1, -1, -1);
    result["bytes_touched"] = 0;
    result["removed_indices"] = removed_indices;
    result["removed_materials"] = removed_materials;
    if (cells.is_empty() || p_radius_voxels <= 0.0 || p_energy <= 0.0) {
        return result;
    }

    const Vector3i low(
            std::max(0, static_cast<int>(std::floor(p_center_voxels.x - p_radius_voxels))),
            std::max(0, static_cast<int>(std::floor(p_center_voxels.y - p_radius_voxels))),
            std::max(0, static_cast<int>(std::floor(p_center_voxels.z - p_radius_voxels))));
    const Vector3i high(
            std::min(dimensions.x - 1, static_cast<int>(std::ceil(p_center_voxels.x + p_radius_voxels))),
            std::min(dimensions.y - 1, static_cast<int>(std::ceil(p_center_voxels.y + p_radius_voxels))),
            std::min(dimensions.z - 1, static_cast<int>(std::ceil(p_center_voxels.z + p_radius_voxels))));
    const double radius_squared = p_radius_voxels * p_radius_voxels;
    Vector3i dirty_min(dimensions.x, dimensions.y, dimensions.z);
    Vector3i dirty_max(-1, -1, -1);
    int removed = 0;
    int removed_foundation = 0;
    uint8_t *write = cells.ptrw();
    for (int z = low.z; z <= high.z; ++z) {
        for (int y = low.y; y <= high.y; ++y) {
            for (int x = low.x; x <= high.x; ++x) {
                const Vector3 delta = Vector3(x + 0.5, y + 0.5, z + 0.5) - p_center_voxels;
                const double distance_squared = delta.length_squared();
                if (distance_squared > radius_squared) {
                    continue;
                }
                const int index = index_of(x, y, z);
                const uint8_t material = write[index];
                if (material == AIR) {
                    continue;
                }
                const double hardness_value = material < p_hardnesses.size()
                        ? std::max(0.001, static_cast<double>(p_hardnesses[material]))
                        : 1.0;
                // Teardown's `MakeHole(body, pos, softRadius, mediumRadius, hardRadius)` gives one
                // radius per toughness class rather than one blast sphere: wide in wood and glass,
                // narrower in brick, a dent in hard masonry, nothing in rock. `radius * energy /
                // hardness` reproduces those concentric radii from a single call, so `radius` is the
                // soft radius and `energy` is how hard the tool punches. The previous rule compared
                // `energy * attenuation` against hardness, and with tool energies ten times the
                // hardest material every impact carved the same perfect sphere of everything.
                const double reach = p_radius_voxels
                        * std::min(1.0, p_energy / hardness_value) * rim_shrink(x, y, z);
                // Below half a voxel there is no hole, only the cell the blast centre happens to sit
                // in. Without this an "unbreakable" material still lost its centre voxel per hit.
                if (reach < 0.5 || distance_squared > reach * reach) {
                    continue;
                }
                write[index] = AIR;
                --occupied_count;
                --material_counts[material];
                ++removed;
                if (p_foundation_threshold >= 0.0
                        && hardness_value >= p_foundation_threshold) {
                    ++removed_foundation;
                }
                reservoir_damage_sample(
                        removed_indices, removed_materials, index, material, removed);
                dirty_min = dirty_min.min(Vector3i(x, y, z));
                dirty_max = dirty_max.max(Vector3i(x, y, z));
            }
        }
    }
    if (removed > 0) {
        const Vector3i macro_low = dirty_min / MACRO_SIZE;
        const Vector3i macro_high = dirty_max / MACRO_SIZE;
        for (int z = macro_low.z; z <= macro_high.z; ++z) {
            for (int y = macro_low.y; y <= macro_high.y; ++y) {
                for (int x = macro_low.x; x <= macro_high.x; ++x) {
                    rebuild_macrocell(x, y, z);
                }
            }
        }
        const Vector3i dirty_size = dirty_max - dirty_min + Vector3i(1, 1, 1);
        result["dirty_min"] = dirty_min;
        result["dirty_max"] = dirty_max;
        result["bytes_touched"] = dirty_size.x * dirty_size.y * dirty_size.z;
        ++content_revision;
    }
    result["removed"] = removed;
    result["removed_foundation"] = removed_foundation;
    result["removed_indices"] = removed_indices;
    result["removed_materials"] = removed_materials;
    return result;
}

Array VoxelShapeData::find_components_6() const {
    Array components;
    if (cells.is_empty()) {
        return components;
    }

    std::vector<uint8_t> visited(static_cast<size_t>(cells.size()), 0);
    std::vector<int32_t> queue;
    queue.reserve(4096);
    const uint8_t *cell_data = cells.ptr();
    const int size_x = dimensions.x;
    const int size_y = dimensions.y;
    const int plane = size_x * size_y;

    // The seed-search scan skips empty macro-cells at once, 512 cells per block. Lee's terrain has
    // 25 M cells and a shell three voxels thick: scanning them individually for seeds took 35 ms per
    // shot, with the same result—no component can start in a block without a live voxel.
    for (int macro = 0; macro < macro_occupancy.size(); ++macro) {
        if (macro_occupancy[macro] == 0) {
            continue;
        }
        const int macro_z = macro / (macro_dimensions.x * macro_dimensions.y);
        const int macro_rest = macro - macro_z * macro_dimensions.x * macro_dimensions.y;
        const int macro_y = macro_rest / macro_dimensions.x;
        const int macro_x = macro_rest - macro_y * macro_dimensions.x;
        for (int sz = macro_z * MACRO_SIZE;
                sz < std::min((macro_z + 1) * MACRO_SIZE, dimensions.z); ++sz) {
        for (int sy = macro_y * MACRO_SIZE;
                sy < std::min((macro_y + 1) * MACRO_SIZE, dimensions.y); ++sy) {
        for (int sx = macro_x * MACRO_SIZE;
                sx < std::min((macro_x + 1) * MACRO_SIZE, dimensions.x); ++sx) {
        const int start = index_of(sx, sy, sz);
        if (cell_data[start] == AIR || visited[static_cast<size_t>(start)] != 0) {
            continue;
        }
                queue.clear();
                queue.push_back(start);
                visited[static_cast<size_t>(start)] = 1;
                size_t cursor = 0;
                while (cursor < queue.size()) {
                    const int index = queue[cursor++];
                    const int cz = index / plane;
                    const int remaining = index - cz * plane;
                    const int cy = remaining / size_x;
                    const int cx = remaining - cy * size_x;
                    const auto enqueue = [&](int neighbor) {
                        if (cell_data[neighbor] == AIR
                                || visited[static_cast<size_t>(neighbor)] != 0) {
                            return;
                        }
                        visited[static_cast<size_t>(neighbor)] = 1;
                        queue.push_back(neighbor);
                    };
                    if (cx + 1 < size_x) enqueue(index + 1);
                    if (cx > 0) enqueue(index - 1);
                    if (cy + 1 < size_y) enqueue(index + size_x);
                    if (cy > 0) enqueue(index - size_x);
                    if (cz + 1 < dimensions.z) enqueue(index + plane);
                    if (cz > 0) enqueue(index - plane);
                }
                PackedInt32Array component;
                component.resize(static_cast<int64_t>(queue.size()));
                if (!queue.empty()) {
                    std::memcpy(component.ptrw(), queue.data(), queue.size() * sizeof(int32_t));
                }
                components.append(component);
        }
        }
        }
    }
    return components;
}

Array VoxelShapeData::find_components_6_with_anchors(
        const PackedInt32Array &p_anchor_indices) const {
    return find_components_6_classified(p_anchor_indices, nullptr, -1.0);
}

Array VoxelShapeData::find_components_6_with_hardness_anchors(
        const PackedFloat32Array &p_hardnesses, double p_threshold) const {
    return find_components_6_classified(PackedInt32Array(), &p_hardnesses, p_threshold);
}

Array VoxelShapeData::find_components_6_classified(
        const PackedInt32Array &p_anchor_indices, const PackedFloat32Array *p_hardnesses,
        double p_threshold) const {
    Array classified;
    last_connectivity_macros_visited = 0;
    last_connectivity_voxels_materialized = 0;
    connectivity_classification_revision = -1;
    connectivity_node_offsets.clear();
    connectivity_node_roots.clear();
    connectivity_root_voxel_counts.clear();
    connectivity_root_members.clear();
    if (cells.is_empty() || occupied_count == 0) {
        return classified;
    }
    if (!connectivity_index_built) {
        const_cast<VoxelShapeData *>(this)->rebuild_connectivity_index();
    }
    const auto exact_fallback = [&]() {
        if (p_hardnesses != nullptr) {
            return find_components_6_with_anchors_reference(
                    get_indices_hardness_at_least(*p_hardnesses, p_threshold));
        }
        return find_components_6_with_anchors_reference(p_anchor_indices);
    };
    if (macro_connectivity.size() != static_cast<size_t>(macro_occupancy.size())) {
        ++connectivity_fallbacks;
        return exact_fallback();
    }

    std::vector<int> offsets(macro_connectivity.size() + 1, 0);
    for (size_t macro = 0; macro < macro_connectivity.size(); ++macro) {
        offsets[macro + 1] = offsets[macro]
                + static_cast<int>(macro_connectivity[macro].components.size());
        if (!macro_connectivity[macro].components.empty()) {
            ++last_connectivity_macros_visited;
        }
    }
    const int node_count = offsets.back();
    if (node_count <= 0) {
        ++connectivity_fallbacks;
        return exact_fallback();
    }

    std::vector<int> parent(static_cast<size_t>(node_count));
    std::vector<uint8_t> rank(static_cast<size_t>(node_count), 0);
    for (int node = 0; node < node_count; ++node) {
        parent[static_cast<size_t>(node)] = node;
    }
    const auto find_root = [&](int node) {
        int root = node;
        while (parent[static_cast<size_t>(root)] != root) {
            root = parent[static_cast<size_t>(root)];
        }
        while (parent[static_cast<size_t>(node)] != node) {
            const int next = parent[static_cast<size_t>(node)];
            parent[static_cast<size_t>(node)] = root;
            node = next;
        }
        return root;
    };
    const auto unite = [&](int a, int b) {
        int root_a = find_root(a);
        int root_b = find_root(b);
        if (root_a == root_b) {
            return;
        }
        if (rank[static_cast<size_t>(root_a)] < rank[static_cast<size_t>(root_b)]) {
            std::swap(root_a, root_b);
        }
        parent[static_cast<size_t>(root_b)] = root_a;
        if (rank[static_cast<size_t>(root_a)] == rank[static_cast<size_t>(root_b)]) {
            ++rank[static_cast<size_t>(root_a)];
        }
    };
    const auto node_at = [&](int x, int y, int z) {
        if (!in_bounds(x, y, z) || cells[index_of(x, y, z)] == AIR) {
            return -1;
        }
        const int mx = x / MACRO_SIZE;
        const int my = y / MACRO_SIZE;
        const int mz = z / MACRO_SIZE;
        const int macro = macro_index_of(mx, my, mz);
        const int local = (x % MACRO_SIZE) + (y % MACRO_SIZE) * MACRO_SIZE
                + (z % MACRO_SIZE) * MACRO_SIZE * MACRO_SIZE;
        const uint16_t label = macro_connectivity[static_cast<size_t>(macro)].labels[local];
        return label == 0 ? -1 : offsets[static_cast<size_t>(macro)] + label - 1;
    };

    // Cross-macro ports are maintained with each dirty macro and its six neighbours. A query now
    // traverses compact component edges only; it never scans the boundary voxels of the complete
    // terrain again.
    for (size_t macro = 0; macro < macro_connectivity.size(); ++macro) {
        const MacroConnectivity &summary = macro_connectivity[macro];
        for (size_t label = 0; label < summary.external_neighbours.size(); ++label) {
            const int source = offsets[macro] + static_cast<int>(label);
            for (const uint64_t encoded : summary.external_neighbours[label]) {
                const int neighbour_macro = static_cast<int>(encoded >> 16);
                const int neighbour_label = static_cast<int>(encoded & 0xffffu);
                if (neighbour_macro < 0
                        || static_cast<size_t>(neighbour_macro) >= macro_connectivity.size()
                        || neighbour_label <= 0
                        || neighbour_label > static_cast<int>(macro_connectivity[
                                static_cast<size_t>(neighbour_macro)].components.size())) {
                    continue;
                }
                unite(source, offsets[static_cast<size_t>(neighbour_macro)]
                        + neighbour_label - 1);
            }
        }
    }

    connectivity_classification_revision = content_revision;
    connectivity_node_offsets = offsets;
    connectivity_node_roots.resize(static_cast<size_t>(node_count));
    for (int node = 0; node < node_count; ++node) {
        connectivity_node_roots[static_cast<size_t>(node)] = find_root(node);
    }
    connectivity_root_voxel_counts.assign(static_cast<size_t>(node_count), 0);
    connectivity_root_members.resize(static_cast<size_t>(node_count));
    for (size_t macro = 0; macro < macro_connectivity.size(); ++macro) {
        const MacroConnectivity &local = macro_connectivity[macro];
        for (size_t label = 0; label < local.components.size(); ++label) {
            const int node = offsets[macro] + static_cast<int>(label);
            const int root = connectivity_node_roots[static_cast<size_t>(node)];
            connectivity_root_voxel_counts[static_cast<size_t>(root)]
                    += local.components[label].count;
            connectivity_root_members[static_cast<size_t>(root)].push_back(
                    (static_cast<uint64_t>(macro) << 32) | static_cast<uint64_t>(label));
        }
    }

    struct GlobalComponentSummary {
        int count = 0;
        int seed_index = -1;
        Vector3i minimum;
        Vector3i maximum;
        std::unordered_map<int, int> layer_counts;
        std::vector<int32_t> anchors;
        int anchor_count = 0;
        int minimum_anchor_y = std::numeric_limits<int>::max();
    };
    std::vector<GlobalComponentSummary> summaries;
    std::unordered_map<int, int> summary_by_root;
    for (size_t macro = 0; macro < macro_connectivity.size(); ++macro) {
        const MacroConnectivity &local = macro_connectivity[macro];
        if (local.components.empty()) {
            continue;
        }
        const int macro_z = static_cast<int>(macro)
                / (macro_dimensions.x * macro_dimensions.y);
        const int rest = static_cast<int>(macro)
                - macro_z * macro_dimensions.x * macro_dimensions.y;
        const int macro_y = rest / macro_dimensions.x;
        for (size_t label = 0; label < local.components.size(); ++label) {
            const int root = find_root(offsets[macro] + static_cast<int>(label));
            auto found = summary_by_root.find(root);
            if (found == summary_by_root.end()) {
                const int new_index = static_cast<int>(summaries.size());
                summary_by_root[root] = new_index;
                summaries.emplace_back();
                found = summary_by_root.find(root);
                summaries.back().minimum = local.components[label].minimum;
                summaries.back().maximum = local.components[label].maximum;
            }
            GlobalComponentSummary &summary = summaries[static_cast<size_t>(found->second)];
            const LocalComponentSummary &component = local.components[label];
            summary.count += component.count;
            if (summary.seed_index < 0) summary.seed_index = component.seed_index;
            summary.minimum = summary.minimum.min(component.minimum);
            summary.maximum = summary.maximum.max(component.maximum);
            for (int local_y = 0; local_y < MACRO_SIZE; ++local_y) {
                if (component.layer_counts[static_cast<size_t>(local_y)] > 0) {
                    summary.layer_counts[macro_y * MACRO_SIZE + local_y]
                            += component.layer_counts[static_cast<size_t>(local_y)];
                }
            }
            if (p_hardnesses != nullptr) {
                for (const MaterialLayerCount &material_layer : component.material_layers) {
                    const double hardness = material_layer.material < p_hardnesses->size()
                            ? static_cast<double>((*p_hardnesses)[material_layer.material]) : 0.0;
                    if (hardness < p_threshold) continue;
                    summary.anchor_count += material_layer.count;
                    summary.minimum_anchor_y = std::min(summary.minimum_anchor_y,
                            macro_y * MACRO_SIZE + material_layer.local_y);
                }
            }
        }
    }
    for (int i = 0; i < p_anchor_indices.size(); ++i) {
        const int index = p_anchor_indices[i];
        if (index < 0 || index >= cells.size() || cells[index] == AIR) {
            continue;
        }
        const int z = index / (dimensions.x * dimensions.y);
        const int remaining = index - z * dimensions.x * dimensions.y;
        const int y = remaining / dimensions.x;
        const int x = remaining - y * dimensions.x;
        const int node = node_at(x, y, z);
        if (node < 0) continue;
        const auto found = summary_by_root.find(find_root(node));
        if (found != summary_by_root.end()) {
            GlobalComponentSummary &summary = summaries[static_cast<size_t>(found->second)];
            summary.anchors.push_back(index);
            ++summary.anchor_count;
            summary.minimum_anchor_y = std::min(summary.minimum_anchor_y, y);
        }
    }

    const bool materialize_all = occupied_count <= 8192;
    for (const GlobalComponentSummary &summary : summaries) {
        Dictionary entry;
        PackedInt32Array indices;
        if (materialize_all) {
            indices = get_component_6(summary.seed_index);
            last_connectivity_voxels_materialized += indices.size();
        }
        PackedInt32Array anchors;
        anchors.resize(static_cast<int64_t>(summary.anchors.size()));
        if (!summary.anchors.empty()) {
            std::memcpy(anchors.ptrw(), summary.anchors.data(),
                    summary.anchors.size() * sizeof(int32_t));
        }
        int support_cross_section = 0;
        if (summary.anchor_count > 0) {
            const int minimum_anchor_y = summary.minimum_anchor_y;
            support_cross_section = std::numeric_limits<int>::max();
            const int band_high = std::min(summary.maximum.y,
                    minimum_anchor_y + SUPPORT_BAND_HEIGHT - 1);
            for (int layer = minimum_anchor_y; layer <= band_high; ++layer) {
                const auto found = summary.layer_counts.find(layer);
                support_cross_section = std::min(support_cross_section,
                        found == summary.layer_counts.end() ? 0 : found->second);
            }
            if (support_cross_section == std::numeric_limits<int>::max()) {
                support_cross_section = 0;
            }
        }
        entry["indices"] = indices;
        entry["indices_materialized"] = materialize_all;
        entry["seed_index"] = summary.seed_index;
        entry["anchored"] = summary.anchor_count > 0;
        entry["anchor_count"] = summary.anchor_count;
        entry["anchor_indices"] = anchors;
        entry["support_cross_section"] = support_cross_section;
        entry["voxel_count"] = summary.count;
        entry["minimum"] = summary.minimum;
        entry["maximum"] = summary.maximum;
        classified.append(entry);
    }
    return classified;
}

PackedInt32Array VoxelShapeData::get_component_6(int p_seed_index) const {
    PackedInt32Array result;
    if (p_seed_index < 0 || p_seed_index >= cells.size() || cells[p_seed_index] == AIR) {
        return result;
    }
    if (connectivity_classification_revision == content_revision
            && connectivity_node_offsets.size() == macro_connectivity.size() + 1
            && !connectivity_node_roots.empty()) {
        const int seed_z = p_seed_index / (dimensions.x * dimensions.y);
        const int seed_remaining = p_seed_index - seed_z * dimensions.x * dimensions.y;
        const int seed_y = seed_remaining / dimensions.x;
        const int seed_x = seed_remaining - seed_y * dimensions.x;
        const int seed_macro = macro_index_of(seed_x / MACRO_SIZE,
                seed_y / MACRO_SIZE, seed_z / MACRO_SIZE);
        const int seed_local = (seed_x % MACRO_SIZE) + (seed_y % MACRO_SIZE) * MACRO_SIZE
                + (seed_z % MACRO_SIZE) * MACRO_SIZE * MACRO_SIZE;
        const uint16_t seed_label = macro_connectivity[
                static_cast<size_t>(seed_macro)].labels[static_cast<size_t>(seed_local)];
        const int seed_node = seed_label == 0 ? -1
                : connectivity_node_offsets[static_cast<size_t>(seed_macro)] + seed_label - 1;
        if (seed_node >= 0 && static_cast<size_t>(seed_node) < connectivity_node_roots.size()) {
            const int target_root = connectivity_node_roots[static_cast<size_t>(seed_node)];
            if (target_root < 0
                    || static_cast<size_t>(target_root) >= connectivity_root_voxel_counts.size()
                    || static_cast<size_t>(target_root) >= connectivity_root_members.size()) {
                return result;
            }
            const int component_count =
                    connectivity_root_voxel_counts[static_cast<size_t>(target_root)];
            result.resize(component_count);
            int32_t *write = result.ptrw();
            int cursor = 0;
            for (const uint64_t encoded :
                    connectivity_root_members[static_cast<size_t>(target_root)]) {
                const size_t macro = static_cast<size_t>(encoded >> 32);
                const size_t label = static_cast<size_t>(encoded & 0xffffffffu);
                if (macro >= macro_connectivity.size()) continue;
                const MacroConnectivity &summary = macro_connectivity[macro];
                if (label >= summary.components.size()) continue;
                const int macro_z = static_cast<int>(macro)
                        / (macro_dimensions.x * macro_dimensions.y);
                const int rest = static_cast<int>(macro)
                        - macro_z * macro_dimensions.x * macro_dimensions.y;
                const int macro_y = rest / macro_dimensions.x;
                const int macro_x = rest - macro_y * macro_dimensions.x;
                const int x0 = macro_x * MACRO_SIZE;
                const int y0 = macro_y * MACRO_SIZE;
                const int z0 = macro_z * MACRO_SIZE;
                const uint16_t wanted = static_cast<uint16_t>(label + 1);
                for (int z = z0; z < std::min(z0 + MACRO_SIZE, dimensions.z); ++z) {
                    for (int y = y0; y < std::min(y0 + MACRO_SIZE, dimensions.y); ++y) {
                        for (int x = x0; x < std::min(x0 + MACRO_SIZE, dimensions.x); ++x) {
                            const int local = (x - x0) + (y - y0) * MACRO_SIZE
                                    + (z - z0) * MACRO_SIZE * MACRO_SIZE;
                            if (summary.labels[static_cast<size_t>(local)] == wanted) {
                                write[cursor++] = index_of(x, y, z);
                            }
                        }
                    }
                }
            }
            if (cursor != component_count) result.resize(cursor);
            return result;
        }
    }
    std::vector<uint8_t> visited(static_cast<size_t>(cells.size()), 0);
    std::vector<int32_t> queue;
    queue.reserve(4096);
    queue.push_back(p_seed_index);
    visited[static_cast<size_t>(p_seed_index)] = 1;
    const int plane = dimensions.x * dimensions.y;
    size_t cursor = 0;
    while (cursor < queue.size()) {
        const int index = queue[cursor++];
        const int z = index / plane;
        const int remaining = index - z * plane;
        const int y = remaining / dimensions.x;
        const int x = remaining - y * dimensions.x;
        const auto enqueue = [&](int neighbour) {
            if (cells[neighbour] == AIR || visited[static_cast<size_t>(neighbour)] != 0) return;
            visited[static_cast<size_t>(neighbour)] = 1;
            queue.push_back(neighbour);
        };
        if (x + 1 < dimensions.x) enqueue(index + 1);
        if (x > 0) enqueue(index - 1);
        if (y + 1 < dimensions.y) enqueue(index + dimensions.x);
        if (y > 0) enqueue(index - dimensions.x);
        if (z + 1 < dimensions.z) enqueue(index + plane);
        if (z > 0) enqueue(index - plane);
    }
    result.resize(static_cast<int64_t>(queue.size()));
    if (!queue.empty()) {
        std::memcpy(result.ptrw(), queue.data(), queue.size() * sizeof(int32_t));
    }
    return result;
}

Dictionary VoxelShapeData::get_connectivity_metrics() const {
    Dictionary result;
    result["macros_visited"] = last_connectivity_macros_visited;
    result["voxels_materialized"] = last_connectivity_voxels_materialized;
    result["fallbacks"] = connectivity_fallbacks;
    return result;
}

void VoxelShapeData::prepare_connectivity_index() {
    if (!connectivity_index_built && occupied_count > 8192) {
        rebuild_connectivity_index();
    }
}

Array VoxelShapeData::find_components_6_with_anchors_reference(
        const PackedInt32Array &p_anchor_indices) const {
    Array classified;
    if (cells.is_empty()) {
        return classified;
    }
    const uint8_t *cell_data = cells.ptr();
    // Without anchors, the mask is unnecessary: no Shape in the Teardown map has them, and
    // reserving and zeroing one byte per cell would waste 25 MB on the terrain volume.
    std::vector<uint8_t> anchor_mask;
    if (!p_anchor_indices.is_empty()) {
        anchor_mask.assign(static_cast<size_t>(cells.size()), 0);
        for (int i = 0; i < p_anchor_indices.size(); ++i) {
            const int index = p_anchor_indices[i];
            if (index >= 0 && index < cells.size() && cell_data[index] != AIR) {
                anchor_mask[static_cast<size_t>(index)] = 1;
            }
        }
    }
    const bool has_anchors = !anchor_mask.empty();

    // Classify during the flood fill. Calling find_components_6() and scanning every resulting
    // component again made support accounting proportional to the live voxel count twice.
    std::vector<uint8_t> visited(static_cast<size_t>(cells.size()), 0);
    std::vector<int32_t> queue;
    queue.reserve(4096);
    std::vector<int> layer_counts(static_cast<size_t>(dimensions.y), 0);
    std::vector<int> touched_layers;
    touched_layers.reserve(static_cast<size_t>(dimensions.y));
    const int size_x = dimensions.x;
    const int size_y = dimensions.y;
    const int plane = size_x * size_y;
    // The seed-search scan skips empty macro-cells at once, 512 cells per block. Lee's terrain has
    // 25 M cells and a shell three voxels thick: scanning them individually for seeds took 35 ms per
    // shot, with the same result—no component can start in a block without a live voxel.
    for (int macro = 0; macro < macro_occupancy.size(); ++macro) {
        if (macro_occupancy[macro] == 0) {
            continue;
        }
        const int macro_z = macro / (macro_dimensions.x * macro_dimensions.y);
        const int macro_rest = macro - macro_z * macro_dimensions.x * macro_dimensions.y;
        const int macro_y = macro_rest / macro_dimensions.x;
        const int macro_x = macro_rest - macro_y * macro_dimensions.x;
        for (int sz = macro_z * MACRO_SIZE;
                sz < std::min((macro_z + 1) * MACRO_SIZE, dimensions.z); ++sz) {
        for (int sy = macro_y * MACRO_SIZE;
                sy < std::min((macro_y + 1) * MACRO_SIZE, dimensions.y); ++sy) {
        for (int sx = macro_x * MACRO_SIZE;
                sx < std::min((macro_x + 1) * MACRO_SIZE, dimensions.x); ++sx) {
        const int start = index_of(sx, sy, sz);
        if (cell_data[start] == AIR || visited[static_cast<size_t>(start)] != 0) {
            continue;
        }
                std::vector<int32_t> live_anchor_indices;
                live_anchor_indices.reserve(256);
                queue.clear();
                touched_layers.clear();
                queue.push_back(start);
                visited[static_cast<size_t>(start)] = 1;
                int minimum_anchor_y = dimensions.y;
                int maximum_component_y = -1;
                Vector3i component_minimum(dimensions.x, dimensions.y, dimensions.z);
                Vector3i component_maximum(-1, -1, -1);
                size_t cursor = 0;
                while (cursor < queue.size()) {
                    const int index = queue[cursor++];
                    const int cz = index / plane;
                    const int remaining = index - cz * plane;
                    const int cy = remaining / size_x;
                    const int cx = remaining - cy * size_x;
                    component_minimum = component_minimum.min(Vector3i(cx, cy, cz));
                    component_maximum = component_maximum.max(Vector3i(cx, cy, cz));
                    if (layer_counts[static_cast<size_t>(cy)] == 0) {
                        touched_layers.push_back(cy);
                    }
                    ++layer_counts[static_cast<size_t>(cy)];
                    maximum_component_y = std::max(maximum_component_y, cy);
                    if (has_anchors && anchor_mask[static_cast<size_t>(index)] != 0) {
                        live_anchor_indices.push_back(index);
                        minimum_anchor_y = std::min(minimum_anchor_y, cy);
                    }
                    const auto enqueue = [&](int neighbor) {
                        if (cell_data[neighbor] == AIR
                                || visited[static_cast<size_t>(neighbor)] != 0) {
                            return;
                        }
                        visited[static_cast<size_t>(neighbor)] = 1;
                        queue.push_back(neighbor);
                    };
                    if (cx + 1 < size_x) enqueue(index + 1);
                    if (cx > 0) enqueue(index - 1);
                    if (cy + 1 < size_y) enqueue(index + size_x);
                    if (cy > 0) enqueue(index - size_x);
                    if (cz + 1 < dimensions.z) enqueue(index + plane);
                    if (cz > 0) enqueue(index - plane);
                }
                PackedInt32Array component;
                component.resize(static_cast<int64_t>(queue.size()));
                if (!queue.empty()) {
                    std::memcpy(component.ptrw(), queue.data(), queue.size() * sizeof(int32_t));
                }
                PackedInt32Array live_anchors;
                live_anchors.resize(static_cast<int64_t>(live_anchor_indices.size()));
                if (!live_anchor_indices.empty()) {
                    std::memcpy(live_anchors.ptrw(), live_anchor_indices.data(),
                            live_anchor_indices.size() * sizeof(int32_t));
                }
                int support_cross_section = 0;
                if (!live_anchors.is_empty()) {
                    support_cross_section = std::numeric_limits<int>::max();
                    const int band_high = std::min(
                            maximum_component_y, minimum_anchor_y + SUPPORT_BAND_HEIGHT - 1);
                    for (int layer = minimum_anchor_y; layer <= band_high; ++layer) {
                        support_cross_section = std::min(
                                support_cross_section, layer_counts[static_cast<size_t>(layer)]);
                    }
                    if (support_cross_section == std::numeric_limits<int>::max()) {
                        support_cross_section = 0;
                    }
                }
                Dictionary entry;
                entry["indices"] = component;
                entry["anchored"] = !live_anchors.is_empty();
                entry["anchor_count"] = live_anchors.size();
                entry["anchor_indices"] = live_anchors;
                entry["support_cross_section"] = support_cross_section;
                entry["voxel_count"] = component.size();
                entry["minimum"] = component_minimum;
                entry["maximum"] = component_maximum;
                classified.append(entry);
                for (const int layer : touched_layers) {
                    layer_counts[static_cast<size_t>(layer)] = 0;
                }
        }
        }
        }
    }
    return classified;
}

bool VoxelShapeData::damage_may_disconnect_6(
        const Vector3i &p_dirty_min, const Vector3i &p_dirty_max, int p_margin) const {
    if (cells.is_empty() || p_dirty_min.x < 0 || p_dirty_max.x < p_dirty_min.x) {
        return false;
    }

    // A destructive edit can only create a new component at the frontier of the cells it removed.
    // Test those frontier voxels in a small native window first. If they are still connected there,
    // they are necessarily connected in the complete Shape and the expensive global flood fill is
    // provably unnecessary. A negative local result is deliberately conservative: the paths may
    // reconnect outside the window, so the caller falls back to the exact global classification.
    const Vector3i dirty_low = p_dirty_min.max(Vector3i());
    const Vector3i dirty_high = p_dirty_max.min(dimensions - Vector3i(1, 1, 1));
    const int margin = std::max(1, p_margin);
    const Vector3i window_low = (dirty_low - Vector3i(margin, margin, margin)).max(Vector3i());
    const Vector3i window_high = (dirty_high + Vector3i(margin, margin, margin))
            .min(dimensions - Vector3i(1, 1, 1));
    const Vector3i window_size = window_high - window_low + Vector3i(1, 1, 1);
    if (window_size.x <= 0 || window_size.y <= 0 || window_size.z <= 0) {
        return false;
    }

    const int local_plane = window_size.x * window_size.y;
    const int local_count = local_plane * window_size.z;
    std::vector<uint8_t> frontier(static_cast<size_t>(local_count), 0);
    std::vector<int> seeds;
    seeds.reserve(64);
    const int directions[6][3] = {
        {1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}
    };
    const auto local_index = [&](int x, int y, int z) {
        return (x - window_low.x) + (y - window_low.y) * window_size.x
                + (z - window_low.z) * local_plane;
    };

    for (int z = dirty_low.z; z <= dirty_high.z; ++z) {
        for (int y = dirty_low.y; y <= dirty_high.y; ++y) {
            for (int x = dirty_low.x; x <= dirty_high.x; ++x) {
                if (cells[index_of(x, y, z)] != AIR) {
                    continue;
                }
                for (const auto &direction : directions) {
                    const int nx = x + direction[0];
                    const int ny = y + direction[1];
                    const int nz = z + direction[2];
                    if (!in_bounds(nx, ny, nz) || nx < window_low.x || ny < window_low.y
                            || nz < window_low.z || nx > window_high.x
                            || ny > window_high.y || nz > window_high.z
                            || cells[index_of(nx, ny, nz)] == AIR) {
                        continue;
                    }
                    const int local = local_index(nx, ny, nz);
                    if (frontier[static_cast<size_t>(local)] == 0) {
                        frontier[static_cast<size_t>(local)] = 1;
                        seeds.push_back(index_of(nx, ny, nz));
                    }
                }
            }
        }
    }
    if (seeds.size() <= 1) {
        return false;
    }

    std::vector<uint8_t> visited(static_cast<size_t>(local_count), 0);
    std::vector<int> queue;
    queue.reserve(4096);
    queue.push_back(seeds.front());
    const int first_z = seeds.front() / (dimensions.x * dimensions.y);
    const int first_remaining = seeds.front() - first_z * dimensions.x * dimensions.y;
    const int first_y = first_remaining / dimensions.x;
    const int first_x = first_remaining - first_y * dimensions.x;
    visited[static_cast<size_t>(local_index(first_x, first_y, first_z))] = 1;
    size_t cursor = 0;
    int reached_frontier = 0;
    while (cursor < queue.size()) {
        const int index = queue[cursor++];
        const int z = index / (dimensions.x * dimensions.y);
        const int remaining = index - z * dimensions.x * dimensions.y;
        const int y = remaining / dimensions.x;
        const int x = remaining - y * dimensions.x;
        const int local = local_index(x, y, z);
        if (frontier[static_cast<size_t>(local)] != 0) {
            ++reached_frontier;
            if (reached_frontier == static_cast<int>(seeds.size())) {
                return false;
            }
        }
        for (const auto &direction : directions) {
            const int nx = x + direction[0];
            const int ny = y + direction[1];
            const int nz = z + direction[2];
            if (nx < window_low.x || ny < window_low.y || nz < window_low.z
                    || nx > window_high.x || ny > window_high.y || nz > window_high.z) {
                continue;
            }
            const int next_local = local_index(nx, ny, nz);
            if (visited[static_cast<size_t>(next_local)] != 0
                    || cells[index_of(nx, ny, nz)] == AIR) {
                continue;
            }
            visited[static_cast<size_t>(next_local)] = 1;
            queue.push_back(index_of(nx, ny, nz));
        }
    }
    return true;
}

bool VoxelShapeData::damage_may_disconnect_6_indexed(
        const Vector3i &p_dirty_min, const Vector3i &p_dirty_max) const {
    if (cells.is_empty() || p_dirty_min.x < 0 || p_dirty_max.x < p_dirty_min.x) {
        return false;
    }
    // Refreshes the compact global roots but, for large Shapes, does not materialize voxel arrays.
    find_components_6_with_anchors(PackedInt32Array());
    if (connectivity_classification_revision != content_revision
            || connectivity_node_offsets.size() != macro_connectivity.size() + 1
            || connectivity_node_roots.empty()) {
        return true;
    }
    const auto root_at = [&](int x, int y, int z) {
        if (!in_bounds(x, y, z) || cells[index_of(x, y, z)] == AIR) return -1;
        const int macro = macro_index_of(x / MACRO_SIZE, y / MACRO_SIZE, z / MACRO_SIZE);
        const int local = (x % MACRO_SIZE) + (y % MACRO_SIZE) * MACRO_SIZE
                + (z % MACRO_SIZE) * MACRO_SIZE * MACRO_SIZE;
        const uint16_t label = macro_connectivity[
                static_cast<size_t>(macro)].labels[static_cast<size_t>(local)];
        if (label == 0) return -1;
        const int node = connectivity_node_offsets[static_cast<size_t>(macro)] + label - 1;
        return connectivity_node_roots[static_cast<size_t>(node)];
    };
    const Vector3i low = p_dirty_min.max(Vector3i());
    const Vector3i high = p_dirty_max.min(dimensions - Vector3i(1, 1, 1));
    const Vector3i directions[6] = {
        Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
        Vector3i(0, 1, 0), Vector3i(0, -1, 0),
        Vector3i(0, 0, 1), Vector3i(0, 0, -1),
    };
    int first_root = -1;
    for (int z = low.z; z <= high.z; ++z) {
        for (int y = low.y; y <= high.y; ++y) {
            for (int x = low.x; x <= high.x; ++x) {
                if (cells[index_of(x, y, z)] != AIR) continue;
                for (const Vector3i &direction : directions) {
                    const Vector3i neighbour = Vector3i(x, y, z) + direction;
                    const int root = root_at(neighbour.x, neighbour.y, neighbour.z);
                    if (root < 0) continue;
                    if (first_root < 0) {
                        first_root = root;
                    } else if (root != first_root) {
                        return true;
                    }
                }
            }
        }
    }
    return false;
}

Dictionary VoxelShapeData::detach_component_except(const PackedInt32Array &p_indices,
        const PackedInt32Array &p_retained_indices) {
    if (p_retained_indices.is_empty()) {
        return detach_component(p_indices);
    }
    std::vector<uint8_t> retained_mask(static_cast<size_t>(cells.size()), 0);
    for (int i = 0; i < p_retained_indices.size(); ++i) {
        const int index = p_retained_indices[i];
        if (index >= 0 && index < cells.size()) {
            retained_mask[static_cast<size_t>(index)] = 1;
        }
    }
    PackedInt32Array detachable;
    for (int i = 0; i < p_indices.size(); ++i) {
        const int index = p_indices[i];
        if (index >= 0 && index < cells.size()
                && retained_mask[static_cast<size_t>(index)] == 0) {
            detachable.append(index);
        }
    }
    return detach_component(detachable);
}

Dictionary VoxelShapeData::detach_component(const PackedInt32Array &p_indices) {
    Dictionary result;
    if (p_indices.is_empty()) {
        return result;
    }
    Vector3i low(dimensions.x, dimensions.y, dimensions.z);
    Vector3i high(-1, -1, -1);
    int live_count = 0;
    for (int i = 0; i < p_indices.size(); ++i) {
        const int index = p_indices[i];
        if (index < 0 || index >= cells.size() || cells[index] == AIR) {
            continue;
        }
        const int z = index / (dimensions.x * dimensions.y);
        const int remaining = index - z * dimensions.x * dimensions.y;
        const int y = remaining / dimensions.x;
        const int x = remaining - y * dimensions.x;
        low = low.min(Vector3i(x, y, z));
        high = high.max(Vector3i(x, y, z));
        ++live_count;
    }
    if (live_count == 0) {
        return result;
    }

    const Vector3i detached_dimensions = high - low + Vector3i(1, 1, 1);
    PackedByteArray detached_cells;
    detached_cells.resize(detached_dimensions.x * detached_dimensions.y * detached_dimensions.z);
    detached_cells.fill(AIR);
    for (int i = 0; i < p_indices.size(); ++i) {
        const int source_index = p_indices[i];
        if (source_index < 0 || source_index >= cells.size() || cells[source_index] == AIR) {
            continue;
        }
        const int z = source_index / (dimensions.x * dimensions.y);
        const int remaining = source_index - z * dimensions.x * dimensions.y;
        const int y = remaining / dimensions.x;
        const int x = remaining - y * dimensions.x;
        const Vector3i local = Vector3i(x, y, z) - low;
        const int target_index = local.x + local.y * detached_dimensions.x +
                local.z * detached_dimensions.x * detached_dimensions.y;
        const uint8_t material = cells[source_index];
        detached_cells.set(target_index, material);
        cells.set(source_index, AIR);
        --occupied_count;
        --material_counts[material];
    }
    const Vector3i macro_low = low / MACRO_SIZE;
    const Vector3i macro_high = high / MACRO_SIZE;
    for (int z = macro_low.z; z <= macro_high.z; ++z) {
        for (int y = macro_low.y; y <= macro_high.y; ++y) {
            for (int x = macro_low.x; x <= macro_high.x; ++x) {
                rebuild_macrocell(x, y, z);
            }
        }
    }
    ++content_revision;

    Ref<VoxelShapeData> detached;
    detached.instantiate();
    detached->set_cells(detached_dimensions, detached_cells);
    result["data"] = detached;
    result["offset"] = low;
    result["dirty_min"] = low;
    result["dirty_max"] = high;
    result["voxel_count"] = live_count;
    return result;
}

Dictionary VoxelShapeData::build_collision_boxes(int p_max_boxes, double p_voxel_size) const {
    Dictionary result;
    const int max_boxes = std::max(1, p_max_boxes);
    const double voxel_size = std::max(0.001, p_voxel_size);
    if (occupied_count == 0) {
        result["boxes"] = Array();
        result["pitch"] = 1;
        result["exact"] = true;
        return result;
    }

    int pitch = 1;
    Array boxes;
    while (true) {
        const Vector3i coarse_dimensions(
                (dimensions.x + pitch - 1) / pitch,
                (dimensions.y + pitch - 1) / pitch,
                (dimensions.z + pitch - 1) / pitch);
        const int row = coarse_dimensions.x;
        const int plane = coarse_dimensions.x * coarse_dimensions.z;
        const size_t coarse_count = static_cast<size_t>(plane * coarse_dimensions.y);
        std::vector<uint8_t> solid(coarse_count, 0);
        std::vector<Vector3i> occupied_low;
        std::vector<Vector3i> occupied_high;
        if (pitch > 1) {
            occupied_low.assign(coarse_count, dimensions);
            occupied_high.assign(coarse_count, Vector3i());
        }
        for (int z = 0; z < dimensions.z; ++z) {
            for (int y = 0; y < dimensions.y; ++y) {
                for (int x = 0; x < dimensions.x; ++x) {
                    if (cells[index_of(x, y, z)] == AIR) {
                        continue;
                    }
                    const int cx = x / pitch;
                    const int cy = y / pitch;
                    const int cz = z / pitch;
                    const size_t coarse_index = static_cast<size_t>(cx + cz * row + cy * plane);
                    solid[coarse_index] = 1;
                    if (pitch > 1) {
                        occupied_low[coarse_index] = occupied_low[coarse_index].min(
                                Vector3i(x, y, z));
                        occupied_high[coarse_index] = occupied_high[coarse_index].max(
                                Vector3i(x + 1, y + 1, z + 1));
                    }
                }
            }
        }

        boxes.clear();
        bool exceeded = false;
        // At reduced resolution, turning one occupied voxel into a complete pitch³ cell creates
        // invisible shelves around sparse poles and lattice towers. Keep one tight AABB per
        // occupied coarse cell instead. It is still conservative inside that local cell, but never
        // merges air across cell boundaries; increasing pitch remains the bounded fallback.
        if (pitch > 1) {
            for (size_t coarse_index = 0; coarse_index < coarse_count; ++coarse_index) {
                if (solid[coarse_index] == 0) {
                    continue;
                }
                const Vector3i low = occupied_low[coarse_index];
                const Vector3i high = occupied_high[coarse_index];
                const Vector3 low_world =
                        (Vector3(low) - Vector3(dimensions) * 0.5) * voxel_size;
                const Vector3 high_world =
                        (Vector3(high) - Vector3(dimensions) * 0.5) * voxel_size;
                Dictionary box;
                box["position"] = (low_world + high_world) * 0.5;
                box["size"] = high_world - low_world;
                boxes.append(box);
                if (boxes.size() > max_boxes) {
                    exceeded = true;
                    break;
                }
            }
            if (!exceeded) {
                break;
            }
            pitch *= 2;
            continue;
        }
        auto row_full = [&](int x, int y, int z, int width) {
            for (int dx = 0; dx < width; ++dx) {
                if (solid[static_cast<size_t>(x + dx + z * row + y * plane)] == 0) {
                    return false;
                }
            }
            return true;
        };
        for (int y = 0; y < coarse_dimensions.y && !exceeded; ++y) {
            for (int z = 0; z < coarse_dimensions.z && !exceeded; ++z) {
                for (int x = 0; x < coarse_dimensions.x; ++x) {
                    if (solid[static_cast<size_t>(x + z * row + y * plane)] == 0) {
                        continue;
                    }
                    int width = 1;
                    while (x + width < coarse_dimensions.x &&
                            solid[static_cast<size_t>(x + width + z * row + y * plane)] != 0) {
                        ++width;
                    }
                    int depth = 1;
                    while (z + depth < coarse_dimensions.z && row_full(x, y, z + depth, width)) {
                        ++depth;
                    }
                    int height = 1;
                    bool can_grow = true;
                    while (y + height < coarse_dimensions.y && can_grow) {
                        for (int dz = 0; dz < depth; ++dz) {
                            if (!row_full(x, y + height, z + dz, width)) {
                                can_grow = false;
                                break;
                            }
                        }
                        if (can_grow) {
                            ++height;
                        }
                    }
                    for (int dy = 0; dy < height; ++dy) {
                        for (int dz = 0; dz < depth; ++dz) {
                            for (int dx = 0; dx < width; ++dx) {
                                solid[static_cast<size_t>(x + dx + (z + dz) * row +
                                        (y + dy) * plane)] = 0;
                            }
                        }
                    }
                    const Vector3i low(x * pitch, y * pitch, z * pitch);
                    const Vector3i high(
                            std::min((x + width) * pitch, dimensions.x),
                            std::min((y + height) * pitch, dimensions.y),
                            std::min((z + depth) * pitch, dimensions.z));
                    const Vector3 low_world = (Vector3(low) - Vector3(dimensions) * 0.5) * voxel_size;
                    const Vector3 high_world = (Vector3(high) - Vector3(dimensions) * 0.5) * voxel_size;
                    Dictionary box;
                    box["position"] = (low_world + high_world) * 0.5;
                    box["size"] = high_world - low_world;
                    boxes.append(box);
                    if (boxes.size() > max_boxes) {
                        exceeded = true;
                        break;
                    }
                }
            }
        }
        if (!exceeded) {
            break;
        }
        pitch *= 2;
    }
    result["boxes"] = boxes;
    result["pitch"] = pitch;
    result["exact"] = pitch == 1;
    result["box_count"] = boxes.size();
    result["voxel_count"] = occupied_count;
    return result;
}

Dictionary VoxelShapeData::calculate_mass_properties(
        const PackedFloat32Array &p_densities, double p_voxel_size) const {
    Dictionary result;
    const double size = std::max(0.001, p_voxel_size);
    const double volume = size * size * size;
    double total_mass = 0.0;
    Vector3 weighted_center;
    for (int z = 0; z < dimensions.z; ++z) {
        for (int y = 0; y < dimensions.y; ++y) {
            for (int x = 0; x < dimensions.x; ++x) {
                const uint8_t material = cells[index_of(x, y, z)];
                if (material == AIR) {
                    continue;
                }
                const double density_value = material < p_densities.size()
                        ? std::max(0.0, static_cast<double>(p_densities[material]))
                        : 1800.0;
                const double mass = density_value * volume;
                const Vector3 center = (Vector3(x + 0.5, y + 0.5, z + 0.5) -
                        Vector3(dimensions) * 0.5) * size;
                total_mass += mass;
                weighted_center += center * mass;
            }
        }
    }
    if (total_mass <= 0.0) {
        result["mass"] = 0.0;
        result["center"] = Vector3();
        result["inertia"] = Vector3(1, 1, 1);
        return result;
    }
    const Vector3 center_of_mass = weighted_center / total_mass;
    const double cube_self_term = size * size / 6.0;
    Vector3 inertia;
    for (int z = 0; z < dimensions.z; ++z) {
        for (int y = 0; y < dimensions.y; ++y) {
            for (int x = 0; x < dimensions.x; ++x) {
                const uint8_t material = cells[index_of(x, y, z)];
                if (material == AIR) {
                    continue;
                }
                const double density_value = material < p_densities.size()
                        ? std::max(0.0, static_cast<double>(p_densities[material]))
                        : 1800.0;
                const double mass = density_value * volume;
                const Vector3 cell_center = (Vector3(x + 0.5, y + 0.5, z + 0.5) -
                        Vector3(dimensions) * 0.5) * size;
                const Vector3 offset = cell_center - center_of_mass;
                inertia += mass * Vector3(
                        offset.y * offset.y + offset.z * offset.z + cube_self_term,
                        offset.x * offset.x + offset.z * offset.z + cube_self_term,
                        offset.x * offset.x + offset.y * offset.y + cube_self_term);
            }
        }
    }
    result["mass"] = total_mass;
    result["center"] = center_of_mass;
    result["inertia"] = inertia;
    result["voxel_count"] = occupied_count;
    return result;
}

Dictionary VoxelShapeData::self_test() const {
    Dictionary result;
    bool valid_size = dimensions.x > 0 && dimensions.y > 0 && dimensions.z > 0;
    bool valid_storage = cells.size() == dimensions.x * dimensions.y * dimensions.z;
    int counted = 0;
    for (int i = 0; i < cells.size(); ++i) {
        counted += cells[i] != AIR ? 1 : 0;
    }
    int64_t counted_by_material = 0;
    for (int material = 1; material < 256; ++material) {
        counted_by_material += material_counts[static_cast<size_t>(material)];
    }
    result["valid_size"] = valid_size;
    result["valid_storage"] = valid_storage;
    result["valid_occupied_count"] = counted == occupied_count;
    result["valid_material_counts"] = counted_by_material == occupied_count;
    result["occupied"] = counted;
    result["components"] = find_components_6().size();
    result["ok"] = valid_size && valid_storage && counted == occupied_count
            && counted_by_material == occupied_count;
    return result;
}
