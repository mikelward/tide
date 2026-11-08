# tide's press-and-hold accents for fcitx5 (SPEC.md §8.6):
#
#   cmake -S fcitx5 -B build/fcitx5 -DCMAKE_BUILD_TYPE=Release
#   cmake --build build/fcitx5
#   sudo cmake --install build/fcitx5
#
# Installs into fcitx5's own directories, wherever its distribution put them.
cmake_minimum_required(VERSION 3.16)
project(tide-accents LANGUAGES CXX)

# C++20: newer fcitx5 headers' logging macros, such as FCITX_ERROR, use
# std::source_location, which is C++20's; older ones build either way.
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(ECM REQUIRED 1.0.0)
set(CMAKE_MODULE_PATH ${ECM_MODULE_PATH} ${CMAKE_MODULE_PATH})

# fcitx5's addon, data and library directories, not CMAKE_INSTALL_PREFIX's.
# Set before find_package, which reads it.
set(FCITX_INSTALL_USE_FCITX_SYS_PATHS ON CACHE BOOL
    "Install into fcitx5's own directories")
find_package(Fcitx5Core REQUIRED)

add_library(tide-accents MODULE tide_accents.cpp accents_core.cpp)
target_link_libraries(tide-accents Fcitx5::Core)
target_compile_options(tide-accents PRIVATE -Wall -Wextra)
set_target_properties(tide-accents PROPERTIES PREFIX "")

install(TARGETS tide-accents DESTINATION "${FCITX_INSTALL_ADDONDIR}")
install(FILES data/tide-accents-addon.conf
        DESTINATION "${FCITX_INSTALL_PKGDATADIR}/addon"
        RENAME tide-accents.conf)
install(FILES data/tide-accents-inputmethod.conf
        DESTINATION "${FCITX_INSTALL_PKGDATADIR}/inputmethod"
        RENAME tide-accents.conf)
# The default table, which a user's ~/.config/tide/accents.json overrides
# letter by letter.
install(FILES accents.json
        DESTINATION "${FCITX_INSTALL_PKGDATADIR}/tide-accents")
