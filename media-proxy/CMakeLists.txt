# SPDX-FileCopyrightText: Copyright (c) 2024 Intel Corporation
#
# SPDX-License-Identifier: BSD-3-Clause

# Minimum CMake required
cmake_minimum_required(VERSION 3.16)

project(MediaProxy VERSION 0.0.1 LANGUAGES CXX C)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -pthread")

# Enabled by default
option(ENABLE_ZERO_COPY "Enable zero-copy mode to avoid memory copying between Media Proxy and MTL" ON)
IF(ENABLE_ZERO_COPY)
	ADD_DEFINITIONS(-DZERO_COPY)
ENDIF(ENABLE_ZERO_COPY)

set(target media_proxy)
set(MTL_LIB mtl)
set(MEMIF_LIB memif)
set(PROTO_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../protos)

# Find Protobuf and gRPC
find_package(Protobuf CONFIG REQUIRED)
message(STATUS "Using protobuf ${Protobuf_VERSION}")
find_package(gRPC CONFIG REQUIRED)
message(STATUS "Using gRPC ${gRPC_VERSION}")

# Ensure that the gRPC plugin is available
find_program(GRPC_CPP_PLUGIN_EXECUTABLE grpc_cpp_plugin)
if(NOT GRPC_CPP_PLUGIN_EXECUTABLE)
    message(FATAL_ERROR "grpc_cpp_plugin not found")
endif()

# Define the .proto files
set(PROTO_FILES
    ${PROTO_DIR}/mediaproxy.proto
    ${PROTO_DIR}/controller.proto
    ${PROTO_DIR}/sdk.proto
)

# Generate the protobuf and gRPC source files
set(PROTO_SRC_DIR "${CMAKE_CURRENT_BINARY_DIR}/generated")
file(MAKE_DIRECTORY ${PROTO_SRC_DIR})

if(CMAKE_CROSSCOMPILING)
  find_program(Protobuf_PROTOC_EXECUTABLE protoc)
else()
  set(Protobuf_PROTOC_EXECUTABLE $<TARGET_FILE:protobuf::protoc>)
endif()

foreach(proto_file ${PROTO_FILES})
    get_filename_component(proto_name ${proto_file} NAME_WE)
    set(proto_srcs "${PROTO_SRC_DIR}/${proto_name}.pb.cc")
    set(proto_hdrs "${PROTO_SRC_DIR}/${proto_name}.pb.h")
    set(grpc_srcs "${PROTO_SRC_DIR}/${proto_name}.grpc.pb.cc")
    set(grpc_hdrs "${PROTO_SRC_DIR}/${proto_name}.grpc.pb.h")

    add_custom_command(
        OUTPUT ${proto_srcs} ${proto_hdrs} ${grpc_srcs} ${grpc_hdrs}
        COMMAND ${Protobuf_PROTOC_EXECUTABLE}
        ARGS --proto_path=${PROTO_DIR}
             --grpc_out=${PROTO_SRC_DIR}
             --cpp_out=${PROTO_SRC_DIR}
             --plugin=protoc-gen-grpc=${GRPC_CPP_PLUGIN_EXECUTABLE}
             ${proto_file}
        DEPENDS ${proto_file}
        COMMENT "Generating Protobuf and gRPC files for ${proto_file}"
    )

    list(APPEND PROTO_SRCS ${proto_srcs})
    list(APPEND PROTO_HDRS ${proto_hdrs})
    list(APPEND GRPC_SRCS ${grpc_srcs})
    list(APPEND GRPC_HDRS ${grpc_hdrs})
endforeach()

# Find source files recursively
file(GLOB_RECURSE proxy_srcs "src/*")

# Exclude media_proxy.cc from proxy_srcs
list(REMOVE_ITEM proxy_srcs "${CMAKE_CURRENT_SOURCE_DIR}/src/media_proxy.cc")

add_definitions(-DHAVE_MEMFD_CREATE)

# Find the libfabric library
find_library(LIBFABRIC NAMES fabric)

# Find the libfabric header files
find_path(LIBFABRIC_INCLUDE_DIR NAMES rdma/fabric.h)

set(CMAKE_INSTALL_PATH ${CMAKE_INSTALL_PREFIX}/bin)
set(CMAKE_CONFIG_PATH ${CMAKE_INSTALL_PREFIX}/etc)
ADD_DEFINITIONS(-DIMTL_CONFIG_PATH=\"${CMAKE_INSTALL_PREFIX}/etc/imtl.json\")
ADD_DEFINITIONS(-D_GNU_SOURCE)

include_directories(
    ${CMAKE_CURRENT_BINARY_DIR}
    ./include
    ./include/mesh
    ${LIBFABRIC_INCLUDE_DIR}
    ${Protobuf_INCLUDE_DIRS}
    ${gRPC_INCLUDE_DIRS}
    ${PROTO_SRC_DIR}  # Include the directory where the generated files are located
)

add_library(media_proxy_lib STATIC ${proxy_srcs} ${PROTO_SRCS} ${PROTO_HDRS} ${GRPC_SRCS}
            ${GRPC_HDRS})
target_link_libraries(media_proxy_lib PUBLIC m ${MTL_LIB} ${MEMIF_LIB} ${LIBFABRIC}
    gRPC::grpc++ protobuf::libprotobuf)

add_executable(media_proxy ${proxy_srcs} src/media_proxy.cc)
target_link_libraries(media_proxy PRIVATE media_proxy_lib)

install(TARGETS media_proxy DESTINATION ${CMAKE_INSTALL_PATH} COMPONENT media_proxy)
install(FILES imtl.json DESTINATION ${CMAKE_CONFIG_PATH} COMPONENT config)
