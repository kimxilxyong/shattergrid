cmake_minimum_required(VERSION 3.22)

project(shattergrid_core LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

include(FetchContent)

set(GODOTCPP_API_VERSION "4.7" CACHE STRING "Godot extension API version" FORCE)
set(GODOTCPP_BUILD_PROFILE "${CMAKE_SOURCE_DIR}/native/build_profile.json" CACHE FILEPATH "Trimmed godot-cpp API" FORCE)

# Pinned instead of following master so a future godot-cpp change cannot silently
# alter the extension ABI. This revision is the current Godot 4.7-compatible head.
FetchContent_Declare(
	godot_cpp
	GIT_REPOSITORY https://github.com/godotengine/godot-cpp.git
	GIT_TAG d7b6162249ed52796a8301d216c24ee71d68c2bf
	GIT_SHALLOW FALSE
)
FetchContent_MakeAvailable(godot_cpp)

add_library(shattergrid_core SHARED
	native/src/register_types.cpp
	native/src/voxel_shape_data.cpp
	native/src/voxel_brick_pool.cpp
	native/src/voxel_palette.cpp
	native/src/voxel_settings.cpp
	native/src/voxel_runtime_registry.cpp
	native/src/voxel_rope_solver.cpp
	native/src/voxel_rope_mesh.cpp
	native/src/voxel_rope_physics_bridge.cpp
	native/src/voxel_transform_tracker.cpp
	native/src/voxel_collision_installer.cpp
	native/src/voxel_map_import_planner.cpp
	native/src/voxel_impact_queue.cpp
	native/src/voxel_collision_handoff_queue.cpp
	native/src/voxel_support_planner.cpp
	native/src/voxel_structural_graph.cpp
	native/src/voxel_damage_planner.cpp
	native/src/voxel_mass_properties.cpp
	native/src/voxel_asset_decoder.cpp
	native/src/voxel_shadow_update_planner.cpp
	native/src/voxel_motion_damage_scanner.cpp
	native/src/voxel_map_scene_traversal.cpp
	native/src/voxel_map_scene_committer.cpp
)

target_include_directories(shattergrid_core PRIVATE native/include)
target_link_libraries(shattergrid_core PRIVATE godot::cpp)
target_compile_definitions(shattergrid_core PRIVATE GODOT_CPP_NO_THREAD_LOCAL)

# A single output directory for all three platforms: the .gdextension descriptor points to
# `native/bin` and cannot follow subdirectories by configuration. `RUNTIME` covers the Windows DLL,
# `LIBRARY` covers the .dylib/.so. Multi-config generators (Visual Studio) also need the
# by-configuration variant or they write back to bin/Release.
set_target_properties(shattergrid_core PROPERTIES
	OUTPUT_NAME "shattergrid_core"
	LIBRARY_OUTPUT_DIRECTORY "${CMAKE_SOURCE_DIR}/native/bin"
	RUNTIME_OUTPUT_DIRECTORY "${CMAKE_SOURCE_DIR}/native/bin"
)
foreach(config IN LISTS CMAKE_CONFIGURATION_TYPES)
	string(TOUPPER "${config}" config_upper)
	set_target_properties(shattergrid_core PROPERTIES
		LIBRARY_OUTPUT_DIRECTORY_${config_upper} "${CMAKE_SOURCE_DIR}/native/bin"
		RUNTIME_OUTPUT_DIRECTORY_${config_upper} "${CMAKE_SOURCE_DIR}/native/bin"
	)
endforeach()

if(APPLE)
	set_target_properties(shattergrid_core PROPERTIES
		BUILD_RPATH "@loader_path"
		INSTALL_RPATH "@loader_path"
	)
endif()

if(WIN32)
	# MinGW prefixes `lib`; MSVC does not. The descriptor declares a single name, so normalize it to
	# de MSVC: shattergrid_core.dll.
	set_target_properties(shattergrid_core PROPERTIES PREFIX "")
endif()

if(MSVC)
	# voxel_shape_data.cpp pasa de 64 K secciones por objeto; ademas las fuentes son UTF-8 y MSVC
	# asume la code page del sistema sin esta opcion.
	target_compile_options(shattergrid_core PRIVATE /bigobj /utf-8 /EHsc)
endif()
