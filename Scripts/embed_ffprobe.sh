#!/bin/zsh

set -euo pipefail

find_ffprobe() {
    local candidate
    for candidate in /opt/homebrew/bin/ffprobe /usr/local/bin/ffprobe; do
        if [[ -x "$candidate" ]]; then
            realpath "$candidate"
            return 0
        fi
    done
    print -u2 "error: 未找到 ffprobe。请先通过 Homebrew 安装 FFmpeg。"
    return 1
}

is_bundled_dependency() {
    [[ "$1" == /opt/homebrew/* || "$1" == /usr/local/* ]]
}

FFPROBE_SOURCE="$(find_ffprobe)"
CONTENTS_DIR="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}"
EXECUTABLE_DIR="${TARGET_BUILD_DIR}/${EXECUTABLE_FOLDER_PATH}"
LIBRARY_DIR="${CONTENTS_DIR}/Frameworks/FFprobeLibraries"
LICENSE_DIR="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/FFmpegLicenses"
FFPROBE_DESTINATION="${EXECUTABLE_DIR}/ffprobe"

rm -rf "$LIBRARY_DIR" "$LICENSE_DIR"
mkdir -p "$EXECUTABLE_DIR" "$LIBRARY_DIR" "$LICENSE_DIR"
cp -L "$FFPROBE_SOURCE" "$FFPROBE_DESTINATION"
chmod 755 "$FFPROBE_DESTINATION"

typeset -A COPIED_DEPENDENCIES

dependency_paths() {
    otool -L "$1" | sed -E '1d; s/^[[:space:]]*([^[:space:]]+).*/\1/'
}

copy_dependency() {
    local requested_path="$1"
    local source_path="$(realpath "$requested_path")"
    local destination_name="${source_path:t}"
    local destination_path="${LIBRARY_DIR}/${destination_name}"
    local dependency

    if [[ -n "${COPIED_DEPENDENCIES[$source_path]-}" ]]; then
        return
    fi
    COPIED_DEPENDENCIES[$source_path]="$destination_path"

    if [[ -e "$destination_path" ]]; then
        print -u2 "error: ffprobe 依赖中存在重名动态库：${destination_name}"
        exit 1
    fi

    cp -L "$source_path" "$destination_path"
    chmod 755 "$destination_path"

    while IFS= read -r dependency; do
        if is_bundled_dependency "$dependency"; then
            copy_dependency "$dependency"
        fi
    done < <(dependency_paths "$source_path")
}

while IFS= read -r dependency; do
    if is_bundled_dependency "$dependency"; then
        copy_dependency "$dependency"
    fi
done < <(dependency_paths "$FFPROBE_SOURCE")

rewrite_dependencies() {
    local file="$1"
    local prefix="$2"
    local dependency resolved name

    while IFS= read -r dependency; do
        if is_bundled_dependency "$dependency"; then
            resolved="$(realpath "$dependency")"
            name="${resolved:t}"
            install_name_tool -change "$dependency" "${prefix}/${name}" "$file"
        fi
    done < <(dependency_paths "$file")
}

rewrite_dependencies "$FFPROBE_DESTINATION" "@executable_path/../Frameworks/FFprobeLibraries"

local_library=""
for local_library in "$LIBRARY_DIR"/*.dylib; do
    rewrite_dependencies "$local_library" "@loader_path"
    install_name_tool -id "@loader_path/${local_library:t}" "$local_library"
done

FFMPEG_PREFIX="${FFPROBE_SOURCE:h:h}"
for license in "$FFMPEG_PREFIX"/LICENSE.md "$FFMPEG_PREFIX"/COPYING*; do
    [[ -f "$license" ]] && cp "$license" "$LICENSE_DIR/"
done

SIGNING_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
[[ -n "$SIGNING_IDENTITY" ]] || SIGNING_IDENTITY="-"

for local_library in "$LIBRARY_DIR"/*.dylib; do
    codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$local_library"
done

codesign \
    --force \
    --sign "$SIGNING_IDENTITY" \
    --timestamp=none \
    --entitlements "${SRCROOT}/Scripts/ffprobe.entitlements" \
    "$FFPROBE_DESTINATION"

echo "已嵌入 ffprobe 和 ${#COPIED_DEPENDENCIES} 个动态库。"

