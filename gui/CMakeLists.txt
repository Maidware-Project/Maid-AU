cmake_minimum_required(VERSION 3.16)

project(maid-au-gui VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 6.4 REQUIRED COMPONENTS Widgets)

add_executable(maid-au-gui
    src/main.cpp
    src/mainwindow.cpp
    src/mainwindow.h
)

target_link_libraries(maid-au-gui PRIVATE Qt6::Widgets)
target_compile_definitions(maid-au-gui PRIVATE MAID_AU_VERSION="${PROJECT_VERSION}")

install(TARGETS maid-au-gui RUNTIME DESTINATION bin)
