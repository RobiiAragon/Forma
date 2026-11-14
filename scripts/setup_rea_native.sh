#!/bin/bash
# Pinned, project-local reverse-engineering tools. Does not modify MCP or shell settings.
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
research_dir="$project_dir/build/Research"
ghidra_archive="$research_dir/ghidra-downloads/ghidra_12.1.4_PUBLIC_20260921.zip"
jdk_archive="$research_dir/jdk-downloads/OpenJDK25U-jdk_aarch64_mac_hotspot_25.0.4.1_1.tar.gz"
ghidra_dir="$research_dir/ghidra_12.1.4_PUBLIC"
jdk_dir="$research_dir/jdk-25.0.4.1+1/Contents/Home"
ghidra_sha=ddac49f903da9d5bac833e5cc79395098b9c33cfd3279be5f31bd00387d2d4db
jdk_sha=61979887f7506a24a57439ff99adb8b3a7fc89977d9cfe3b8984f58a981b7b9d

if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    printf '%s\n' 'This pinned setup targets macOS arm64.' >&2
    exit 1
fi

mkdir -p "$(dirname "$ghidra_archive")" "$(dirname "$jdk_archive")"
download_verified() {
    local destination="$1" expected="$2" url="$3"
    if [[ ! -f "$destination" ]] || ! printf '%s  %s\n' "$expected" "$destination" | shasum -a 256 -c - >/dev/null 2>&1; then
        curl --fail --location --retry 3 --output "$destination.download" "$url"
        printf '%s  %s\n' "$expected" "$destination.download" | shasum -a 256 -c - >&2
        mv "$destination.download" "$destination"
    fi
    printf '%s  %s\n' "$expected" "$destination" | shasum -a 256 -c - >&2
}
download_verified "$ghidra_archive" "$ghidra_sha" \
    'https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_12.1.4_build/ghidra_12.1.4_PUBLIC_20260921.zip'
download_verified "$jdk_archive" "$jdk_sha" \
    'https://github.com/adoptium/temurin25-binaries/releases/download/jdk-25.0.4.1%2B1/OpenJDK25U-jdk_aarch64_mac_hotspot_25.0.4.1_1.tar.gz'

if [[ ! -f "$ghidra_dir/Ghidra/application.properties" ]]; then
    ditto -x -k "$ghidra_archive" "$research_dir"
fi
if [[ ! -x "$jdk_dir/bin/javac" ]]; then
    tar -xzf "$jdk_archive" -C "$research_dir"
fi

decompiler_dir="$ghidra_dir/Ghidra/Features/Decompiler/os/mac_arm_64"
if [[ ! -x "$decompiler_dir/decompile" ]]; then
    (
        cd "$ghidra_dir/Ghidra/Features/Decompiler/src/decompile/cpp"
        make -j4 ghidra_opt ARCH_TYPE='-arch arm64' OSDIR=mac_arm_64
        mkdir -p "$decompiler_dir"
        # Preserve any already existing component; never overwrite another installation.
        test ! -e "$decompiler_dir/decompile"
        test ! -L "$decompiler_dir/decompile"
        install -m 755 ghidra_opt "$decompiler_dir/decompile"
    )
fi

export GHIDRA_INSTALL_DIR="$ghidra_dir"
export JAVA_HOME="$jdk_dir"
export REA_ANALYSIS_PROVIDER=ghidra

if [[ "${1:-}" == --install-only ]]; then
    "$JAVA_HOME/bin/java" -version
    file "$decompiler_dir/decompile"
    exit 0
fi

# An existing compatible Node is selected without modifying the user's PATH.
node_executable="${REA_NODE_EXECUTABLE:-~/.nvm/versions/node/v22.23.3/bin/node}"
rea_entry="$research_dir/rea-cli/node_modules/rea-agents/scripts/rea.mjs"
test -x "$node_executable"
test -f "$rea_entry"
if [[ $# -eq 0 ]]; then
    set -- doctor --format json
fi
exec "$node_executable" "$rea_entry" "$@"
