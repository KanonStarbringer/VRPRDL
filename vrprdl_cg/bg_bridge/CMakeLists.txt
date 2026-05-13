cmake_minimum_required(VERSION 3.22)
project(bg_pricing_bridge LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

add_library(bg_pricing_bridge SHARED
    src/bg_pricing_c.cpp
)

target_include_directories(bg_pricing_bridge
    PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}/include
        ${CMAKE_CURRENT_SOURCE_DIR}/../third_party/bucket-graph-spprc/include
)

if (MSVC)
    target_compile_options(bg_pricing_bridge PRIVATE /W3)
else()
    target_compile_options(bg_pricing_bridge PRIVATE -O3 -Wall -Wextra -Wno-unused-parameter)
endif()

add_executable(bgp_solve_once tools/bgp_solve_once.cpp)
target_link_libraries(bgp_solve_once PRIVATE bg_pricing_bridge)
set_target_properties(bgp_solve_once PROPERTIES RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR})
if (UNIX AND NOT APPLE)
    set_target_properties(bgp_solve_once PROPERTIES
        BUILD_RPATH "$ORIGIN"
        INSTALL_RPATH "$ORIGIN")
elseif (APPLE)
    set_target_properties(bgp_solve_once PROPERTIES
        BUILD_RPATH "@loader_path"
        INSTALL_RPATH "@loader_path")
endif()
