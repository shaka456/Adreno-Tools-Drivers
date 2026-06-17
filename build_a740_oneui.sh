#!/bin/bash -e
set -o pipefail

deps="git meson ninja patchelf unzip curl pip flex bison zip glslangValidator python3"
workdir="$(pwd)/turnip_workdir"
ndkver="android-ndk-r29"
buildtype="release"
MESA_COMMIT="3da4653d46"

check_deps(){
    for dep in $deps; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            echo "Missing: $dep"; exit 1
        fi
    done
    pip install mako --break-system-packages &>/dev/null || true
}

prepare_ndk(){
    mkdir -p "$workdir" && cd "$workdir"
    if [ ! -d "$ndkver" ]; then
        curl -sL "https://dl.google.com/android/repository/${ndkver}-linux.zip" -o "${ndkver}-linux.zip"
        unzip -q "${ndkver}-linux.zip"
    fi
    export ANDROID_NDK_HOME="$workdir/$ndkver"
}

clone_mesa(){
    cd "$workdir"
    rm -rf mesa
    git clone https://gitlab.freedesktop.org/mesa/mesa.git mesa
    cd mesa
    git checkout "$MESA_COMMIT"

    mkdir -p subprojects && cd subprojects
    rm -rf spirv-tools spirv-headers
    git clone --depth=1 https://github.com/KhronosGroup/SPIRV-Tools.git spirv-tools
    git clone --depth=1 https://github.com/KhronosGroup/SPIRV-Headers.git spirv-headers
    cd ..
}

apply_patches(){
    cd "$workdir/mesa"

    sed -i 's/ (%s)//g' src/freedreno/vulkan/tu_device.cc 2>/dev/null || true
    sed -i 's/ (%s)//g' src/freedreno/vulkan/tu_device.c 2>/dev/null || true

    sed -i '/a7xx_gen1 = GPUProps(/a \        has_early_preamble = False,' src/freedreno/common/freedreno_devices.py 2>/dev/null || true
    sed -i '/a7xx_gen2 = GPUProps(/a \        has_early_preamble = False,' src/freedreno/common/freedreno_devices.py 2>/dev/null || true

    sed -i 's/typedef const native_handle_t\* buffer_handle_t;/typedef void\* buffer_handle_t;/g' include/android_stub/cutils/native_handle.h 2>/dev/null || true
    sed -i 's/, hnd->handle/, (void *)hnd->handle/g' src/util/u_gralloc/u_gralloc_fallback.c 2>/dev/null || true
    sed -i 's/native_buffer->handle->/((const native_handle_t *)native_buffer->handle)->/g' src/vulkan/runtime/vk_android.c 2>/dev/null || true
    sed -i 's/anb->handle->/((const native_handle_t *)anb->handle)->/g' src/vulkan/runtime/vk_android.c 2>/dev/null || true

    # Add IMPLEMENTATION_DEFINED case (Samsung camera) after B8G8R8A8
    sed -i '/case AHARDWAREBUFFER_FORMAT_B8G8R8A8_UNORM:/a\   case AHARDWAREBUFFER_FORMAT_IMPLEMENTATION_DEFINED:\n      return VK_FORMAT_R8G8B8A8_UNORM;' src/vulkan/runtime/vk_android.c 2>/dev/null || true

    # For Skia compatibility: return RGBA for ANY unknown AHB format (YUV, etc.)
    sed -i '/^   default:$/{n;s/return VK_FORMAT_UNDEFINED/return VK_FORMAT_R8G8B8A8_UNORM/;}' src/vulkan/runtime/vk_android.c 2>/dev/null || true

    # Query formatFeatures for p->format (RGBA) instead of external_format (YUV multi-planar)
    # so Skia gets proper SAMPLED_IMAGE_BIT for AutoBackendTextureRelease
    sed -i 's/external_format, &format_properties);/p->format, \&format_properties);/' src/vulkan/runtime/vk_android.c 2>/dev/null || true
}

build_mesa(){
    cd "$workdir/mesa"

    local ndk_bin="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
    local ndk_sys="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
    local sdk="36"
    [ ! -f "$ndk_bin/aarch64-linux-android${sdk}-clang" ] && sdk="35"
    [ ! -f "$ndk_bin/aarch64-linux-android${sdk}-clang" ] && sdk="34"

    mkdir -p "$workdir/bin"
    ln -sf "$ndk_bin/clang" "$workdir/bin/cc"
    ln -sf "$ndk_bin/clang++" "$workdir/bin/c++"

    export PATH="$workdir/bin:$ndk_bin:$PATH"
    export CC=clang
    export CXX=clang++
    export AR=llvm-ar
    export RANLIB=llvm-ranlib
    export STRIP=llvm-strip
    export LDFLAGS="-fuse-ld=lld"
    export CFLAGS="-D__ANDROID__ -Wno-error -Wno-deprecated-declarations"
    export CXXFLAGS="-D__ANDROID__ -Wno-error -Wno-deprecated-declarations -Wno-c++11-narrowing"

    cat <<EOF >android-aarch64.txt
[binaries]
ar = '$ndk_bin/llvm-ar'
c = ['ccache', '$ndk_bin/aarch64-linux-android${sdk}-clang', '--sysroot=$ndk_sys']
cpp = ['ccache', '$ndk_bin/aarch64-linux-android${sdk}-clang++', '--sysroot=$ndk_sys', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '-static-libstdc++']
c_ld = '$ndk_bin/ld.lld'
cpp_ld = '$ndk_bin/ld.lld'
strip = '$ndk_bin/llvm-strip'

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

    cat <<EOF >native.txt
[build_machine]
c = ['ccache', 'clang']
cpp = ['ccache', 'clang++']
ar = 'llvm-ar'
strip = 'llvm-strip'
c_ld = 'ld.lld'
cpp_ld = 'ld.lld'
system = 'linux'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF

    meson setup build-aarch64 \
        --cross-file android-aarch64.txt \
        --native-file native.txt \
        -Dbuildtype=$buildtype \
        -Dstrip=true \
        -Dplatforms=android \
        -Dvideo-codecs= \
        -Dplatform-sdk-version=$sdk \
        -Dandroid-stub=true \
        -Dgallium-drivers= \
        -Dvulkan-drivers=freedreno \
        -Dvulkan-beta=true \
        -Dfreedreno-kmds=kgsl \
        -Degl=disabled \
        -Dglx=disabled \
        -Ddefault_library=shared \
        -Dzstd=disabled \
        -Dwerror=false \
        --force-fallback-for=spirv-tools,spirv-headers

    ninja -C build-aarch64

    local lib="build-aarch64/src/freedreno/vulkan/libvulkan_freedreno.so"
    if [ ! -f "$lib" ]; then
        echo "BUILD FAILED"; exit 1
    fi
}

package(){
    local tag="V97-A740-OneUI"
    local pkg_dir="$workdir/pkg_$tag"
    mkdir -p "$pkg_dir"

    cp "$workdir/mesa/build-aarch64/src/freedreno/vulkan/libvulkan_freedreno.so" "$pkg_dir/vulkan.adreno.so"
    cd "$pkg_dir"
    patchelf --set-soname "vulkan.adreno.so" vulkan.adreno.so
    llvm-strip --strip-all -o vulkan.adreno.so.stripped vulkan.adreno.so 2>/dev/null && mv vulkan.adreno.so.stripped vulkan.adreno.so || true

    GITHASH=$(cd "$workdir/mesa" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")

    cat <<EOF >meta.json
{
  "schemaVersion": 1,
  "name": "Turnip A740 OneUI",
  "description": "A740 OneUI build with AHB fix",
  "author": "shaka456",
  "packageVersion": "1",
  "vendor": "Mesa",
  "driverVersion": "26.2.0-devel ($GITHASH)",
  "minApi": 28,
  "libraryName": "vulkan.adreno.so"
}
EOF

    zip -9 "$workdir/Turnip-A740-OneUI-${tag}.zip" vulkan.adreno.so meta.json
    echo "Done: Turnip-A740-OneUI-${tag}.zip"
}

check_deps
prepare_ndk
clone_mesa
apply_patches
build_mesa
package
