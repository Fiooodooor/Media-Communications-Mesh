#!/bin/bash

# SPDX-License-Identifier: BSD-3-Clause
# Copyright 2024 Intel Corporation

set -eo pipefail

SCRIPT_DIR="$(readlink -f "$(dirname -- "${BASH_SOURCE[0]}")")"
REPOSITORY_DIR="$(readlink -f "${SCRIPT_DIR}/..")"
BUILD_DIR="${BUILD_DIR:-${SCRIPT_DIR}/build}"

# shellcheck source="../scripts/common.sh"
. "${REPOSITORY_DIR}/scripts/common.sh"

cp -f "${SCRIPT_DIR}/mcm_"* "${BUILD_DIR}/FFmpeg/libavdevice/"

make -C "${BUILD_DIR}/FFmpeg/" -j "$(nproc)"
$AS_ROOT make -C "${BUILD_DIR}/FFmpeg/" install

log_info "FFmpeg MCM plugin build completed."
log_info "\t${BUILD_DIR}/FFmpeg"
