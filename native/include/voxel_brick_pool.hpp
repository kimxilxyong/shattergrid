#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/vector3i.hpp>

#include "voxel_shape_data.hpp"

namespace godot {

/// Store of 8x8x8 bricks for the voxel atlas.
///
/// The dense atlas reserved the full volume of every Shape: on the Teardown map, that is 453 M
/// cells for 79 M filled voxels, only 17% occupancy, and too much for the GPU. Here, a macrocell
/// is reserved only when it contains something, and the shader accesses it through a
/// `macrocell -> slot` table. Empty space no longer consumes VRAM.
///
/// The buffer deliberately lives in C++: GDScript `PackedByteArray`s are copy-on-write, so passing
/// a 150 MB pool to a function to write into it would copy the whole buffer for every Shape.
class VoxelBrickPool : public RefCounted {
    GDCLASS(VoxelBrickPool, RefCounted)

public:
    static constexpr int BRICK = VoxelShapeData::MACRO_SIZE;
    static constexpr int BRICK_CELLS = BRICK * BRICK * BRICK;

private:
    PackedByteArray bytes;
    Vector3i grid;
    int used = 0;

    void write_brick_cells(const VoxelShapeData &p_data, int p_slot, int p_mx, int p_my, int p_mz);

protected:
    static void _bind_methods();

public:
    bool configure(const Vector3i &p_grid);
    void reset();

    Vector3i get_grid() const;
    /// Dimensions of the 3D texture, in texels.
    Vector3i get_dimensions() const;
    int get_capacity() const;
    int get_used() const;
    PackedByteArray get_bytes() const;
    Vector3i get_slot_origin(int p_slot) const;

    /// Reserves a brick for each occupied macrocell in the Shape and returns the
    /// `macrocell index -> slot` table (-1 where there is no data). Empty if the pool is full.
    PackedInt32Array append_shape(const Ref<VoxelShapeData> &p_data);

    /// Rewrites a brick after an impact and returns its 512 bytes packed for upload.
    PackedByteArray refresh_brick(const Ref<VoxelShapeData> &p_data, int p_slot, const Vector3i &p_macro);

    /// Packs the bricks `[p_base, p_base + p_count)`—those of a newly added Shape, which are
    /// contiguous—into batches ready for `VoxelAtlas3D.update_compact_regions`.
    Array extract_uploads(int p_base, int p_count) const;
};

} // namespace godot
