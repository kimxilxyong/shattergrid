#pragma once

#include <array>
#include <cstdint>
#include <vector>

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/typed_array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/vector3i.hpp>

namespace godot {

class VoxelShapeData : public Resource {
    GDCLASS(VoxelShapeData, Resource)

public:
    static constexpr int AIR = 0;
    static constexpr int MACRO_SIZE = 8;

private:
    struct MaterialLayerCount {
        uint8_t material = 0;
        uint8_t local_y = 0;
        uint16_t count = 0;
    };

    struct LocalComponentSummary {
        int count = 0;
        int seed_index = -1;
        Vector3i minimum;
        Vector3i maximum;
        std::array<int, MACRO_SIZE> layer_counts{};
        std::vector<MaterialLayerCount> material_layers;
    };

    struct MacroConnectivity {
        std::vector<uint16_t> labels;
        std::vector<LocalComponentSummary> components;
        std::vector<std::vector<uint64_t>> external_neighbours;
    };

    Vector3i dimensions;
    Vector3i macro_dimensions;
    PackedByteArray cells;
    PackedByteArray macro_occupancy;
    int occupied_count = 0;
    int64_t content_revision = 0;
    std::array<int64_t, 256> material_counts{};
    std::vector<MacroConnectivity> macro_connectivity;
    bool connectivity_index_built = false;
    mutable int last_connectivity_macros_visited = 0;
    mutable int last_connectivity_voxels_materialized = 0;
    mutable int connectivity_fallbacks = 0;
    mutable int64_t connectivity_classification_revision = -1;
    mutable std::vector<int> connectivity_node_offsets;
    mutable std::vector<int> connectivity_node_roots;
    // Root -> voxel count and (macrocell, local label) pairs. Avoids rescanning a Shape's thousands
    // of macrocells for every structural contact candidate.
    mutable std::vector<int> connectivity_root_voxel_counts;
    mutable std::vector<std::vector<uint64_t>> connectivity_root_members;

    int index_of(int x, int y, int z) const;
    int macro_index_of(int x, int y, int z) const;
    bool in_bounds(int x, int y, int z) const;
    void rebuild_macrocell(int mx, int my, int mz, bool p_rebuild_adjacency = true);
    void rebuild_macro_connectivity(int mx, int my, int mz);
    void rebuild_macro_adjacency(int mx, int my, int mz);
    void rebuild_connectivity_index();
    void rebuild_macrocells();
    Array find_components_6_classified(const PackedInt32Array &p_anchor_indices,
            const PackedFloat32Array *p_hardnesses, double p_threshold) const;

protected:
    static void _bind_methods();

public:
    void configure(const Vector3i &p_dimensions);
    bool set_cells(const Vector3i &p_dimensions, const PackedByteArray &p_cells);
    bool set_cells_from_xyzi(const Vector3i &p_source_size, const PackedByteArray &p_xyzi);
    int hollow(int p_shell);
    void generate_prototype(int p_size = 64);

    Vector3i get_dimensions() const;
    Vector3i get_macro_dimensions() const;
    PackedByteArray get_cells() const;
    PackedByteArray get_used_materials() const;
    PackedByteArray get_macro_occupancy() const;
    int get_occupied_count() const;
    int64_t get_content_revision() const;
    int get_cell(int p_x, int p_y, int p_z) const;
    bool set_cell(int p_x, int p_y, int p_z, int p_material);
    PackedInt32Array get_occupied_macros() const;
    PackedInt32Array get_live_indices() const;
    PackedInt32Array get_live_indices_region(const Vector3i &p_low, const Vector3i &p_high) const;
    PackedByteArray rasterize_occupancy_region(const Transform3D &p_transform, double p_voxel_size,
            const Vector3i &p_world_low, const Vector3i &p_logical_size, double p_cell_size,
            const Vector3i &p_packed_size, const PackedByteArray &p_target) const;
    bool has_hardness_at_least(const PackedFloat32Array &p_hardnesses, double p_threshold) const;
    int count_hardness_at_least(
            const PackedFloat32Array &p_hardnesses, double p_threshold) const;
    PackedInt32Array get_indices_hardness_at_least(
            const PackedFloat32Array &p_hardnesses, double p_threshold) const;
    bool touches(const Ref<VoxelShapeData> &p_other, const Transform3D &p_other_to_self,
            double p_self_voxel_size, double p_other_voxel_size, double p_margin,
            int p_max_scan) const;
    bool component_touches(const PackedInt32Array &p_indices,
            const Ref<VoxelShapeData> &p_other, const Transform3D &p_other_to_self,
            double p_self_voxel_size, double p_other_voxel_size, double p_margin) const;
    bool component_seed_touches(int p_seed_index,
            const Ref<VoxelShapeData> &p_other, const Transform3D &p_other_to_self,
            double p_self_voxel_size, double p_other_voxel_size, double p_margin) const;
    static PackedByteArray rasterize_occupancy_level(const TypedArray<VoxelShapeData> &p_shapes,
            const TypedArray<Transform3D> &p_transforms, const PackedFloat32Array &p_voxel_sizes,
            const Vector3i &p_world_low, const Vector3i &p_logical_size, double p_cell_size,
            const Vector3i &p_packed_size);

    Dictionary damage_sphere(const Vector3 &p_center_voxels, double p_radius_voxels, double p_energy = 1.0);
    Dictionary damage_sphere_material(const Vector3 &p_center_voxels, double p_radius_voxels,
            double p_energy, const PackedFloat32Array &p_hardnesses,
            double p_foundation_threshold = -1.0);
    Array find_components_6() const;
    Array find_components_6_with_anchors(const PackedInt32Array &p_anchor_indices) const;
    Array find_components_6_with_hardness_anchors(const PackedFloat32Array &p_hardnesses,
            double p_threshold) const;
    Array find_components_6_with_anchors_reference(const PackedInt32Array &p_anchor_indices) const;
    PackedInt32Array get_component_6(int p_seed_index) const;
    Dictionary get_connectivity_metrics() const;
    void prepare_connectivity_index();
    bool damage_may_disconnect_6(const Vector3i &p_dirty_min, const Vector3i &p_dirty_max,
            int p_margin = 16) const;
    bool damage_may_disconnect_6_indexed(
            const Vector3i &p_dirty_min, const Vector3i &p_dirty_max) const;
    Dictionary detach_component(const PackedInt32Array &p_indices);
    Dictionary detach_component_except(const PackedInt32Array &p_indices,
            const PackedInt32Array &p_retained_indices);
    Dictionary build_collision_boxes(int p_max_boxes = 128, double p_voxel_size = 0.1) const;
    PackedVector3Array build_macro_faces(const Vector3i &p_macro, double p_voxel_size = 0.1,
            int p_block = 1, int p_lod = 1,
            const PackedByteArray &p_collidable = PackedByteArray()) const;
    Dictionary calculate_mass_properties(const PackedFloat32Array &p_densities,
            double p_voxel_size = 0.1) const;
    Dictionary self_test() const;
};

} // namespace godot
