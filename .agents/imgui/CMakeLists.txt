cmake_minimum_required(VERSION 3.16)
project(showtime_imgui LANGUAGES CXX)

find_package(SDL3 CONFIG REQUIRED)

add_library(showtime_imgui STATIC
	"${IMGUI_SOURCE_DIR}/imgui.cpp"
	"${IMGUI_SOURCE_DIR}/imgui_demo.cpp"
	"${IMGUI_SOURCE_DIR}/imgui_draw.cpp"
	"${IMGUI_SOURCE_DIR}/imgui_tables.cpp"
	"${IMGUI_SOURCE_DIR}/imgui_widgets.cpp"
	"${IMGUI_SOURCE_DIR}/backends/imgui_impl_sdl3.cpp"
	"${IMGUI_SOURCE_DIR}/backends/imgui_impl_sdlrenderer3.cpp"
	"${IMGUI_BINDINGS_DIR}/dcimgui/dcimgui_nodefaultargfunctions.cpp"
	"${IMGUI_BINDINGS_DIR}/dcimgui/dcimgui_nodefaultargfunctions_internal.cpp"
)
target_include_directories(showtime_imgui PRIVATE
	"${IMGUI_SOURCE_DIR}"
	"${IMGUI_BINDINGS_DIR}/dcimgui"
)
target_link_libraries(showtime_imgui PRIVATE SDL3::Headers)
target_compile_features(showtime_imgui PRIVATE cxx_std_11)
target_compile_definitions(showtime_imgui PRIVATE
	IMGUI_DISABLE_OBSOLETE_FUNCTIONS
	"IMGUI_IMPL_API=extern \"C\""
)
target_compile_options(showtime_imgui PRIVATE
	-stdlib=libc++ -fno-exceptions -fno-rtti -fno-threadsafe-statics
)
set_target_properties(showtime_imgui PROPERTIES
	POSITION_INDEPENDENT_CODE ON
	PREFIX ""
	OUTPUT_NAME imgui_linux_x64
	ARCHIVE_OUTPUT_DIRECTORY "${IMGUI_BINDINGS_DIR}"
)
