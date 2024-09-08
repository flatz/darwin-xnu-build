#!/usr/bin/env bash

# CREDIT: https://github.com/pwn0rz/xnu-build

set -o errexit
set -o nounset
set -o pipefail
if [[ "${TRACE-0}" == "1" ]]; then
    set -o xtrace
fi

# Colors
export ESC_SEQ="\x1b["
export COL_RESET=$ESC_SEQ"39;49;00m"
export COL_RED=$ESC_SEQ"31;01m"
export COL_GREEN=$ESC_SEQ"32;01m"
export COL_YELLOW=$ESC_SEQ"33;01m"
export COL_BLUE=$ESC_SEQ"34;01m"
export COL_MAGENTA=$ESC_SEQ"35;01m"
export COL_CYAN=$ESC_SEQ"36;01m"

function running() {
    echo -e "$COL_MAGENTA ⇒ $COL_RESET""$1"
}

function info() {
    echo -e "$COL_BLUE[info] $COL_RESET""$1"
}

function error() {
    echo -e "$COL_RED[error] $COL_RESET""$1"
}

# Config
: ${KERNEL_CONFIG:=RELEASE}
: ${ARCH_CONFIG:=ARM64}
: ${MACHINE_CONFIG:=VMAPPLE}
: ${MACOS_VERSION:=""}
: ${JSONDB:=0}
: ${BUILDKC:=0}
: ${CODEQL:=0}
: ${KC_FILTER:='com.apple.driver.SEPHibernation'}
: ${KDK_DST_DIR:='/Library/Developer/KDKs'}

WORK_DIR="$PWD"
CACHE_DIR="${WORK_DIR}/.cache"
BUILD_DIR="${WORK_DIR}/build"
FAKEROOT_DIR="${WORK_DIR}/fakeroot"
SOURCES_DIR="${WORK_DIR}/sources"
DSTROOT="${FAKEROOT_DIR}"

HAVE_WE_INSTALLED_HEADERS_YET="${FAKEROOT_DIR}/.xnu_headers_installed"

KERNEL_FRAMEWORK_ROOT='/System/Library/Frameworks/Kernel.framework/Versions/A'
KC_VARIANT=$(echo "$KERNEL_CONFIG" | tr '[:upper:]' '[:lower:]')
KERNEL_TYPE="${KC_VARIANT}.$(echo "$MACHINE_CONFIG" | tr '[:upper:]' '[:lower:]')"

help() {
    echo 'Usage: build.sh [-h] [--clean] [--clean-partial] [--kc] [--kdk-dirs <dir>]

This script builds the macOS XNU kernel

Where:
    -h|--help       show this help text
    -c|--clean      cleans build artifacts and cloned repos
    --clean-partial cleans build artifacts
    -k|--kc         create kernel collection (via kmutil create)
    --kdk-dirs      override default KDK installation location
'
    exit 0
}

clean() {
    running "Cleaning build directories and extra repos..."
    declare -a paths_to_delete=(
        "${BUILD_DIR}"
        "${FAKEROOT_DIR}"
        "${WORK_DIR}/xnu"
        "${WORK_DIR}/bootstrap_cmds"
        "${WORK_DIR}/dtrace"
        "${WORK_DIR}/AvailabilityVersions"
        "${WORK_DIR}/Libsystem"
        "${WORK_DIR}/libplatform"
        "${WORK_DIR}/libdispatch"
    )

    for path in "${paths_to_delete[@]}"; do
        info "Will delete ${path}"
    done

    read -p "Are you sure? " -n 1 -r
    echo # (optional) move to a new line
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        for path in "${paths_to_delete[@]}"; do
            info "Deleting ${path}"
            rm -rf "${path}"
        done
    fi
}

clean_partial() {
    running "Cleaning build directories..."
    declare -a paths_to_delete=(
        "${BUILD_DIR}"
        "${FAKEROOT_DIR}"
    )

    for path in "${paths_to_delete[@]}"; do
        info "Will delete ${path}"
    done

    read -p "Are you sure? " -n 1 -r
    echo # (optional) move to a new line
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        for path in "${paths_to_delete[@]}"; do
            info "Deleting ${path}"
            rm -rf "${path}"
        done
    fi
}

install_deps() {
    if [ ! -x "$(command -v jq)" ] || [ ! -x "$(command -v gum)" ] || [ ! -x "$(command -v xcodes)" ] || [ ! -x "$(command -v cmake)" ] || [ ! -x "$(command -v ninja)" ]; then
        running "Installing dependencies"
        if [ ! -x "$(command -v brew)" ]; then
            error "Please install homebrew - https://brew.sh (or install 'jq', 'gum' and 'xcodes' manually)"
            read -p "Install homebrew now? " -n 1 -r
            echo # (optional) move to a new line
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                running "Installing homebrew"
                /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
            else
                exit 1
            fi
        fi
        brew install jq gum xcodes bash cmake ninja pbzx aria2
    fi
    if compgen -G "/Applications/Xcode*.app" >/dev/null; then
        info "Xcode is already installed: $(xcode-select -p)"
    else
        running "Installing XCode"
        ipsw download dev --more --output /tmp
        XCODE_VERSION=$(ls /tmp/Xcode_*.xip | sed -E 's/.*Xcode_(.*).xip/\1/')
        xcodes install "${XCODE_VERSION}" --experimental-unxip --color --select --path "/tmp/Xcode_${XCODE_VERSION}.xip"
        # xcodebuild -downloadAllPlatforms
        xcodebuild -runFirstLaunch
    fi
}

install_ipsw() {
    if [ ! -x "$(command -v ipsw)" ]; then
        running "Installing ipsw..."
        brew install blacktop/tap/ipsw
    fi
}

choose_xnu() {
    if [ -z "$MACOS_VERSION" ]; then
        gum style --border normal --margin "1" --padding "1 2" --border-foreground 212 "Choose $(gum style --foreground 212 'macOS') version to build:"
        MACOS_VERSION=$(gum choose "12.5" "13.0" "13.1" "13.2" "13.3" "13.4" "13.5" "14.0" "14.1" "14.2" "14.3" "14.4" "14.5" "14.6")
    fi
    info "MacOS version: ${MACOS_VERSION}"

    BUILD_SUFFIX="${ARCH_CONFIG,,}_${MACHINE_CONFIG,,}_${KERNEL_CONFIG,,}_${MACOS_VERSION//./_}"
    BUILD_DIR="${BUILD_DIR}_${BUILD_SUFFIX}"
    info "Build directory: ${BUILD_DIR}"

    TIGHTBEAMC="tightbeamc-not-supported"

    case ${MACOS_VERSION} in
    '12.5')
         RELEASE_URL='https://raw.githubusercontent.com/apple-oss-distributions/distribution-macOS/macos-125/release.json'
         KDK_NAME='Kernel Debug Kit 12.5 build 21G72'
         KDK_FOLDER_NAME='KDK_12.5_21G72.kdk'
         RC_DARWIN_KERNEL_VERSION='22.6.0'
         ;;
    '13.0')
        RELEASE_URL='https://raw.githubusercontent.com/apple-oss-distributions/distribution-macOS/macos-130/release.json'
        KDK_NAME='Kernel Debug Kit 13.0 build 22A380'
        KDK_FOLDER_NAME='KDK_13.0_22A380.kdk'
        RC_DARWIN_KERNEL_VERSION='22.1.0'
        ;;
    '13.1')
        RELEASE_URL='https://raw.githubusercontent.com/apple-oss-distributions/distribution-macOS/macos-131/release.json'
        KDK_NAME='Kernel Debug Kit 13.1 build 22C65'
        KDK_FOLDER_NAME='KDK_13.1_22C65.kdk'
        RC_DARWIN_KERNEL_VERSION='22.2.0'
        ;;
    '13.2')
        RELEASE_URL='https://raw.githubusercontent.com/apple-oss-distributions/distribution-macOS/macos-132/release.json'
        KDK_NAME='Kernel Debug Kit 13.2 build 22D49'
        KDK_FOLDER_NAME='KDK_13.2_22D49.kdk'
        RC_DARWIN_KERNEL_VERSION='22.3.0'
        ;;
    '13.3')
        RELEASE_URL='https://raw.githubusercontent.com/apple-oss-distributions/distribution-macOS/macos-133/release.json'
        KDK_NAME='Kernel Debug Kit 13.3 build 22E252'
        KDK_FOLDER_NAME='KDK_13.3_22E252.kdk'
        RC_DARWIN_KERNEL_VERSION='22.4.0'
        ;;
    '13.4')
        RELEASE_URL='https://raw.githubusercontent.com/apple-oss-distributions/distribution-macOS/macos-134/release.json'
        KDK_NAME='Kernel Debug Kit 13.4 build 22F66'
        KDK_FOLDER_NAME='KDK_13.4_22F66.kdk'
        RC_DARWIN_KERNEL_VERSION='22.5.0'
        ;;
    '13.5')
        RELEASE_URL='https://raw.githubusercontent.com/apple-oss-distributions/distribution-macOS/macos-135/release.json'
        KDK_NAME='Kernel Debug Kit 13.5 build 22G74'
        KDK_FOLDER_NAME='KDK_13.5_22G74.kdk'
        RC_DARWIN_KERNEL_VERSION='22.6.0'
        ;;
    '14.0')
        RELEASE_URL='https://raw.githubusercontent.com/apple-oss-distributions/distribution-macOS/macos-140/release.json'
        KDK_NAME='Kernel Debug Kit 14.0 build 23A344'
        KDK_FOLDER_NAME='KDK_14.0_23A344.kdk'
        RC_DARWIN_KERNEL_VERSION='23.0.0'
        ;;
    '14.1')
        RELEASE_URL='https://raw.githubusercontent.com/apple-oss-distributions/distribution-macOS/macos-141/release.json'
        KDK_NAME='Kernel Debug Kit 14.1 build 23B74'
        KDK_FOLDER_NAME='KDK_14.1_23B74.kdk'
        RC_DARWIN_KERNEL_VERSION='23.1.0'
        ;;
    '14.2')
        RELEASE_URL='https://raw.githubusercontent.com/apple-oss-distributions/distribution-macOS/macos-142/release.json'
        KDK_NAME='Kernel Debug Kit 14.2 build 23C64'
        KDK_FOLDER_NAME='KDK_14.2_23C64.kdk'
        RC_DARWIN_KERNEL_VERSION='23.2.0'
        ;;
    '14.3')
        RELEASE_URL='https://raw.githubusercontent.com/apple-oss-distributions/distribution-macOS/macos-143/release.json'
        KDK_NAME='Kernel Debug Kit 14.3 build 23D56'
        KDK_FOLDER_NAME='KDK_14.3_23D56.kdk'
        RC_DARWIN_KERNEL_VERSION='23.3.0'
        ;;
    '14.4')
        RELEASE_URL='https://raw.githubusercontent.com/apple-oss-distributions/distribution-macOS/macos-144/release.json'
        KDK_NAME='Kernel Debug Kit 14.4 build 23E214'
        KDK_FOLDER_NAME='KDK_14.4_23E214.kdk'
        RC_DARWIN_KERNEL_VERSION='23.4.0'
        ;;
    '14.5')
        RELEASE_URL='https://raw.githubusercontent.com/apple-oss-distributions/distribution-macOS/macos-145/release.json'
        KDK_NAME='Kernel Debug Kit 14.5 build 23F79'
        KDK_FOLDER_NAME='KDK_14.5_23F79.kdk'
        RC_DARWIN_KERNEL_VERSION='23.5.0'
        ;;
    '14.6')
        RELEASE_URL='https://raw.githubusercontent.com/apple-oss-distributions/distribution-macOS/macos-146/release.json'
        KDK_NAME='Kernel Debug Kit 14.6 build 23G80'
        KDK_FOLDER_NAME='KDK_14.6_23G80.kdk'
        RC_DARWIN_KERNEL_VERSION='23.6.0'
        ;;
    *)
        error "Invalid xnu version"
        exit 1
        ;;
    esac
    KDK_FOLDER_NAME="${KDK_FOLDER_NAME//KDK_/}"
    KDK_FOLDER_NAME="${KDK_FOLDER_NAME//.kdk/}"
    KDKROOT="${KDK_DST_DIR}/${KDK_FOLDER_NAME}"
    if [ "${KDKROOT:0:9}" == "/Library/" ]; then
        KDK_TMP_DIR=/tmp
    else
        KDK_TMP_DIR="${KDK_DST_DIR}"
    fi
    KDK_FILE_NAME="${KDK_NAME// /_}.dmg"
    KDK_DMG_PATH="${KDK_TMP_DIR}/${KDK_FILE_NAME}"
    KDK_MOUNT_PATH="/tmp/${KDK_FOLDER_NAME}"
    info "Building XNU for macOS ${MACOS_VERSION}"
    info "KDK root directory: ${KDKROOT}"
    info "KDK .dmg path: ${KDK_DMG_PATH}"
    if [ ! -d "$KDKROOT" ]; then
        if [ ! -f "$KDK_DMG_PATH" ]; then
            KDK_URL=$(curl -s "https://raw.githubusercontent.com/dortania/KdkSupportPkg/gh-pages/manifest.json" | jq -r --arg KDK_NAME "$KDK_NAME" '.[] | select(.name==$KDK_NAME) | .url')
            running "Downloading ${KDK_NAME} to ${KDK_DMG_PATH}"
            #curl --progress-bar --max-time 900 --connect-timeout 60 -L -o "${KDK_DMG_PATH}" "${KDK_URL}"
            aria2c -c -x 4 -t 60 -m 0 --retry-wait=3 --allow-overwrite=true --always-resume=true --auto-file-renaming=false -d "${KDK_TMP_DIR}" -o "${KDK_FILE_NAME}" "${KDK_URL}"
        fi
        running "Installing KDK from ${KDK_DMG_PATH}"
        mkdir -p "${KDK_MOUNT_PATH}"
        hdiutil attach -readonly -mountpoint "${KDK_MOUNT_PATH}" "${KDK_DMG_PATH}"
        if [ ! -d "${KDKROOT}" ]; then
            if [ "${KDKROOT:0:9}" == "/Library/" ]; then
                sudo mkdir -p "${KDKROOT}"
                sudo chmod 755 "${KDKROOT}"
            else
                mkdir -p "${KDKROOT}"
                chmod 755 "${KDKROOT}"
            fi
        fi
        if [ "${KDKROOT:0:9}" == "/Library/" ]; then
            sudo installer -pkg '/Volumes/Kernel Debug Kit/KernelDebugKit.pkg' -target /
        else
            cd "${KDKROOT}"
            xar -f "${KDK_MOUNT_PATH}/KernelDebugKit.pkg" -x
            pbzx -n 'KDK.pkg/Payload' | cpio -i
            rm -rf 'Distribution' 'Resources' 'KDK.pkg'
            cd "${WORK_DIR}"
        fi
        hdiutil detach "${KDK_MOUNT_PATH}"
        rmdir "${KDK_MOUNT_PATH}"
        ls -lah "${KDK_DST_DIR}"
    fi
}

venv() {
    if [ ! -d "${WORK_DIR}/venv" ]; then
        running "Creating virtual environment"
        python3 -m venv "${WORK_DIR}/venv"
    fi
    info "Activating virtual environment"
    source "${WORK_DIR}/venv/bin/activate"
}

get_xnu() {
    mkdir -p "${SOURCES_DIR}"
    running "💾 Getting xnu files"
    if [ -e "${WORK_DIR}/xnu" ]; then
        if [ ! -L "${WORK_DIR}/xnu" ]; then
            error "${WORK_DIR}/xnu should be a symbolic link"
            exit 1
        fi
        rm "${WORK_DIR}/xnu"
    fi
    XNU_VERSION=$(curl -s $RELEASE_URL | jq -r '.projects[] | select(.project=="xnu") | .tag')
    XNU_DIR="${SOURCES_DIR}/${XNU_VERSION}"
    info "XNU version: ${XNU_VERSION}"
    info "XNU directory: ${XNU_DIR}"
    if [ ! -d "${XNU_DIR}" ]; then
        running "⬇️ Cloning xnu"
        git clone --branch "${XNU_VERSION}" https://github.com/apple-oss-distributions/xnu.git "${XNU_DIR}"
    fi
    ln -s "${XNU_DIR}" "${WORK_DIR}/xnu"

    if [ -f "${CACHE_DIR}/${MACOS_VERSION}/compile_commands.json" ]; then
        info "Restoring cached ${CACHE_DIR}/${MACOS_VERSION}/compile_commands.json"
        cp -f "${CACHE_DIR}/${MACOS_VERSION}/compile_commands.json" "${WORK_DIR}/xnu"
    fi
}

patches() {
    running "🩹 Patching xnu files"
    # xnu headers patch
    sed -i '' 's|^AVAILABILITY_PL="${SDKROOT}/${DRIVERKITROOT}|AVAILABILITY_PL="${FAKEROOT_DIR}|g' "${WORK_DIR}/xnu/bsd/sys/make_symbol_aliasing.sh"
    # libsyscall patch
    sed -i '' 's|^#include.*BSD.xcconfig.*||g' "${WORK_DIR}/xnu/libsyscall/Libsyscall.xcconfig"
    # xnu build patch
    sed -i '' 's|^LDFLAGS_KERNEL_SDK	= -L$(SDKROOT).*|LDFLAGS_KERNEL_SDK	= -L$(FAKEROOT_DIR)/usr/local/lib/kernel -lfirehose_kernel|g' "${WORK_DIR}/xnu/makedefs/MakeInc.def"
    sed -i '' 's|^INCFLAGS_SDK	= -I$(SDKROOT)|INCFLAGS_SDK	= -I$(FAKEROOT_DIR)|g' "${WORK_DIR}/xnu/makedefs/MakeInc.def"
    # specify location of mig (bootstrap_cmds)
    sed -i '' 's|export MIG := $(shell $(XCRUN) -sdk $(SDKROOT) -find mig)|export MIG := $(shell find $(FAKEROOT_DIR) -name "mig")|g' "${WORK_DIR}/xnu/makedefs/MakeInc.cmd"
    sed -i '' 's|export MIGCOM := $(shell $(XCRUN) -sdk $(SDKROOT) -find migcom)|export MIGCOM := $(shell find $(FAKEROOT_DIR) -name "migcom")|g' "${WORK_DIR}/xnu/makedefs/MakeInc.cmd"
    # Don't apply patches when building CodeQL database to keep code pure
    if [ "$CODEQL" -eq "0" ]; then
       PATCH_DIR=""
        case ${MACOS_VERSION} in
        '12.5' | '13.0' | '13.1' | '13.2' | '13.3' | '13.4' | '13.5' | '14.0' | '14.1' | '14.2' | '14.3')
            PATCH_DIR="${WORK_DIR}/patches"
            ;;
        '14.4' | '14.5' | '14.6')
            PATCH_DIR="${WORK_DIR}/patches/14.4"
            ;;
        *)
            error "Invalid xnu version"
            exit 1
            ;;
        esac
        cd "${WORK_DIR}/xnu"
        for PATCH in "${PATCH_DIR}"/*.patch; do
            if git apply --check "$PATCH" 2> /dev/null; then
                running "Applying patch: ${PATCH}"
                git apply "$PATCH"
            fi
        done
        cd "${WORK_DIR}"
    fi
}

build_bootstrap_cmds() {
    if [ ! "$(find "${FAKEROOT_DIR}" -name 'mig' | wc -l)" -gt 0 ]; then
        running "📦 Building bootstrap_cmds"

        if [ -e "${WORK_DIR}/bootstrap_cmds" ]; then
            if [ ! -L "${WORK_DIR}/bootstrap_cmds" ]; then
                error "${WORK_DIR}/bootstrap_cmds should be a symbolic link"
                exit 1
            fi
            rm "${WORK_DIR}/bootstrap_cmds"
        fi
        BOOTSTRAP_VERSION=$(curl -s $RELEASE_URL | jq -r '.projects[] | select(.project=="bootstrap_cmds") | .tag')
        BOOTSTRAP_CMDS_DIR="${SOURCES_DIR}/${BOOTSTRAP_VERSION}"
        info "bootstrap_cmds version: ${BOOTSTRAP_VERSION}"
        info "bootstrap_cmds directory: ${BOOTSTRAP_CMDS_DIR}"
        if [ ! -d "${BOOTSTRAP_CMDS_DIR}" ]; then
            git clone --branch "${BOOTSTRAP_VERSION}" https://github.com/apple-oss-distributions/bootstrap_cmds.git "${BOOTSTRAP_CMDS_DIR}"
        fi
        ln -s "${BOOTSTRAP_CMDS_DIR}" "${WORK_DIR}/bootstrap_cmds"

        SRCROOT="${WORK_DIR}/bootstrap_cmds"
        OBJROOT="${BUILD_DIR}/bootstrap_cmds.obj"
        SYMROOT="${BUILD_DIR}/bootstrap_cmds.sym"

        sed -i '' 's|-o root -g wheel||g' "${WORK_DIR}/bootstrap_cmds/xcodescripts/install-mig.sh"

        CLONED_BOOTSTRAP_VERSION=$(cd "${WORK_DIR}/bootstrap_cmds"; git describe --always 2>/dev/null)

        cd "${SRCROOT}"
        xcodebuild install -sdk macosx -project mig.xcodeproj ARCHS="arm64 x86_64" CODE_SIGN_IDENTITY="-" OBJROOT="${OBJROOT}" SYMROOT="${SYMROOT}" DSTROOT="${DSTROOT}" RC_ProjectNameAndSourceVersion="${CLONED_BOOTSTRAP_VERSION}"
        cd "${WORK_DIR}"
    fi
}

build_dtrace() {
    if [ ! "$(find "${FAKEROOT_DIR}" -name 'ctfmerge' | wc -l)" -gt 0 ]; then
        running "📦 Building dtrace"

       if [ -e "${WORK_DIR}/dtrace" ]; then
            if [ ! -L "${WORK_DIR}/dtrace" ]; then
                error "${WORK_DIR}/dtrace should be a symbolic link"
                exit 1
            fi
            rm "${WORK_DIR}/dtrace"
        fi
        DTRACE_VERSION=$(curl -s $RELEASE_URL | jq -r '.projects[] | select(.project=="dtrace") | .tag')
        DTRACE_DIR="${SOURCES_DIR}/${DTRACE_VERSION}"
        info "dtrace version: ${DTRACE_VERSION}"
        info "dtrace directory: ${DTRACE_DIR}"
        if [ ! -d "${DTRACE_DIR}" ]; then
            git clone --branch "${DTRACE_VERSION}" https://github.com/apple-oss-distributions/dtrace.git "${DTRACE_DIR}"
        fi
        ln -s "${DTRACE_DIR}" "${WORK_DIR}/dtrace"

        SRCROOT="${WORK_DIR}/dtrace"
        OBJROOT="${BUILD_DIR}/dtrace.obj"
        SYMROOT="${BUILD_DIR}/dtrace.sym"

        cd "${SRCROOT}"
        xcodebuild install -sdk macosx -target ctfconvert -target ctfdump -target ctfmerge ARCHS="arm64 x86_64" CODE_SIGN_IDENTITY="-" OBJROOT="${OBJROOT}" SYMROOT="${SYMROOT}" DSTROOT="${DSTROOT}"
        cd "${WORK_DIR}"
    fi
}

build_availabilityversions() {
    if [ ! "$(find "${FAKEROOT_DIR}" -name 'availability.pl' | wc -l)" -gt 0 ]; then
        running "📦 Building AvailabilityVersions"

       if [ -e "${WORK_DIR}/AvailabilityVersions" ]; then
            if [ ! -L "${WORK_DIR}/AvailabilityVersions" ]; then
                error "${WORK_DIR}/AvailabilityVersions should be a symbolic link"
                exit 1
            fi
            rm "${WORK_DIR}/AvailabilityVersions"
        fi
        AVAILABILITYVERSIONS_VERSION=$(curl -s $RELEASE_URL | jq -r '.projects[] | select(.project=="AvailabilityVersions") | .tag')
        AVAILABILITYVERSIONS_DIR="${SOURCES_DIR}/${AVAILABILITYVERSIONS_VERSION}"
        info "AvailabilityVersions version: ${AVAILABILITYVERSIONS_VERSION}"
        info "AvailabilityVersions directory: ${AVAILABILITYVERSIONS_DIR}"
        if [ ! -d "${AVAILABILITYVERSIONS_DIR}" ]; then
            git clone --branch "${AVAILABILITYVERSIONS_VERSION}" https://github.com/apple-oss-distributions/AvailabilityVersions.git "${AVAILABILITYVERSIONS_DIR}"
        fi
        ln -s "${AVAILABILITYVERSIONS_DIR}" "${WORK_DIR}/AvailabilityVersions"

        SRCROOT="${WORK_DIR}/AvailabilityVersions"
        OBJROOT="${BUILD_DIR}/"
        SYMROOT="${BUILD_DIR}/"

        cd "${SRCROOT}"
        make install -j8 OBJROOT="${OBJROOT}" SYMROOT="${SYMROOT}" DSTROOT="${DSTROOT}"
        cd "${WORK_DIR}"
    fi
}

xnu_headers() {
    if [ ! -f "${HAVE_WE_INSTALLED_HEADERS_YET}" ]; then
        running "Installing xnu headers"

        SRCROOT="${WORK_DIR}/xnu"
        OBJROOT="${BUILD_DIR}/xnu-hdrs.obj"
        SYMROOT="${BUILD_DIR}/xnu-hdrs.sym"

        cd "${SRCROOT}"
        make installhdrs SDKROOT=macosx ARCH_CONFIGS="X86_64 ARM64" OBJROOT="${OBJROOT}" SYMROOT="${SYMROOT}" DSTROOT="${DSTROOT}" FAKEROOT_DIR="${FAKEROOT_DIR}" KDKROOT="${KDKROOT}" TIGHTBEAMC=${TIGHTBEAMC} RC_DARWIN_KERNEL_VERSION=${RC_DARWIN_KERNEL_VERSION}
        cd "${WORK_DIR}"
        touch "${HAVE_WE_INSTALLED_HEADERS_YET}"
    fi
}

libsystem_headers() {
    if [ ! -d "${FAKEROOT_DIR}/System/Library/Frameworks/System.framework" ]; then
        running "Installing Libsystem headers"

       if [ -e "${WORK_DIR}/Libsystem" ]; then
            if [ ! -L "${WORK_DIR}/Libsystem" ]; then
                error "${WORK_DIR}/Libsystem should be a symbolic link"
                exit 1
            fi
            rm "${WORK_DIR}/Libsystem"
        fi
        LIBSYSTEM_VERSION=$(curl -s $RELEASE_URL | jq -r '.projects[] | select(.project=="Libsystem") | .tag')
        LIBSYSTEM_DIR="${SOURCES_DIR}/${LIBSYSTEM_VERSION}"
        info "Libsystem version: ${LIBSYSTEM_VERSION}"
        info "Libsystem directory: ${LIBSYSTEM_DIR}"
        if [ ! -d "${LIBSYSTEM_DIR}" ]; then
            git clone --branch "${LIBSYSTEM_VERSION}" https://github.com/apple-oss-distributions/Libsystem.git "${LIBSYSTEM_DIR}"
        fi
        ln -s "${LIBSYSTEM_DIR}" "${WORK_DIR}/Libsystem"

        sed -i '' 's|^#include.*BSD.xcconfig.*||g' "${WORK_DIR}/Libsystem/Libsystem.xcconfig"

        SRCROOT="${WORK_DIR}/Libsystem"
        OBJROOT="${BUILD_DIR}/Libsystem.obj"
        SYMROOT="${BUILD_DIR}/Libsystem.sym"

        cd "${SRCROOT}"
        xcodebuild installhdrs -sdk macosx ARCHS="arm64 arm64e" VALID_ARCHS="arm64 arm64e" OBJROOT="${OBJROOT}" SYMROOT="${SYMROOT}" DSTROOT="${DSTROOT}" FAKEROOT_DIR="${FAKEROOT_DIR}"
        cd "${WORK_DIR}"
    fi
}

libsyscall_headers() {
    if [ ! -f "${FAKEROOT_DIR}/usr/include/os/proc.h" ]; then
        running "Installing libsyscall headers"

        SRCROOT="${WORK_DIR}/xnu/libsyscall"
        OBJROOT="${BUILD_DIR}/libsyscall.obj"
        SYMROOT="${BUILD_DIR}/libsyscall.sym"

        cd "${SRCROOT}"
        xcodebuild installhdrs -sdk macosx TARGET_CONFIGS="$KERNEL_CONFIG $ARCH_CONFIG $MACHINE_CONFIG" ARCHS="arm64 arm64e" VALID_ARCHS="arm64 arm64e" OBJROOT="${OBJROOT}" SYMROOT="${SYMROOT}" DSTROOT="${DSTROOT}" FAKEROOT_DIR="${FAKEROOT_DIR}"
        cd "${WORK_DIR}"
    fi
}

build_libplatform() {
    if [ ! -f "${FAKEROOT_DIR}/usr/local/include/_simple.h" ]; then
        running "📦 Building libplatform"

       if [ -e "${WORK_DIR}/libplatform" ]; then
            if [ ! -L "${WORK_DIR}/libplatform" ]; then
                error "${WORK_DIR}/libplatform should be a symbolic link"
                exit 1
            fi
            rm "${WORK_DIR}/libplatform"
        fi
        LIBPLATFORM_VERSION=$(curl -s $RELEASE_URL | jq -r '.projects[] | select(.project=="libplatform") | .tag')
        LIBPLATFORM_DIR="${SOURCES_DIR}/${LIBPLATFORM_VERSION}"
        info "libplatform version: ${LIBPLATFORM_VERSION}"
        info "libplatform directory: ${LIBPLATFORM_DIR}"
        if [ ! -d "${LIBPLATFORM_DIR}" ]; then
            git clone --branch "${LIBPLATFORM_VERSION}" https://github.com/apple-oss-distributions/libplatform.git "${LIBPLATFORM_DIR}"
        fi
        ln -s "${LIBPLATFORM_DIR}" "${WORK_DIR}/libplatform"

        SRCROOT="${WORK_DIR}/libplatform"

        cd "${SRCROOT}"
        ditto "${SRCROOT}/include" "${DSTROOT}/usr/local/include"
        ditto "${SRCROOT}/private" "${DSTROOT}/usr/local/include"
        cd "${WORK_DIR}"
    fi
}

build_libdispatch() {
    if [ ! -f "${FAKEROOT_DIR}/usr/local/lib/kernel/libfirehose_kernel.a" ]; then
        running "📦 Building libdispatch"

       if [ -e "${WORK_DIR}/libdispatch" ]; then
            if [ ! -L "${WORK_DIR}/libdispatch" ]; then
                error "${WORK_DIR}/libdispatch should be a symbolic link"
                exit 1
            fi
            rm "${WORK_DIR}/libdispatch"
        fi
        LIBDISPATCH_VERSION=$(curl -s $RELEASE_URL | jq -r '.projects[] | select(.project=="libdispatch") | .tag')
        LIBDISPATCH_DIR="${SOURCES_DIR}/${LIBDISPATCH_VERSION}"
        info "libdispatch version: ${LIBDISPATCH_VERSION}"
        info "libdispatch directory: ${LIBDISPATCH_DIR}"
        if [ ! -d "${LIBDISPATCH_DIR}" ]; then
            git clone --branch "${LIBDISPATCH_VERSION}" https://github.com/apple-oss-distributions/libdispatch.git "${LIBDISPATCH_DIR}"
        fi
        ln -s "${LIBDISPATCH_DIR}" "${WORK_DIR}/libdispatch"

        SRCROOT="${WORK_DIR}/libdispatch"
        OBJROOT="${BUILD_DIR}/libfirehose_kernel.obj"
        SYMROOT="${BUILD_DIR}/libfirehose_kernel.sym"

        # libfirehose_kernel patch
        sed -i '' 's|$(SDKROOT)/System/Library/Frameworks/Kernel.framework/PrivateHeaders|$(FAKEROOT_DIR)/System/Library/Frameworks/Kernel.framework/PrivateHeaders|g' "${SRCROOT}/xcodeconfig/libfirehose_kernel.xcconfig"
        sed -i '' 's|$(SDKROOT)/usr/local/include|$(FAKEROOT_DIR)/usr/local/include|g' "${SRCROOT}/xcodeconfig/libfirehose_kernel.xcconfig"

        cd "${SRCROOT}"
        xcodebuild install -target libfirehose_kernel -sdk macosx ARCHS="x86_64 arm64e" VALID_ARCHS="x86_64 arm64e" OBJROOT="${OBJROOT}" SYMROOT="${SYMROOT}" DSTROOT="${DSTROOT}" FAKEROOT_DIR="${FAKEROOT_DIR}"
        cd "${WORK_DIR}"

        mv "${FAKEROOT_DIR}/usr/local/lib/kernel/liblibfirehose_kernel.a" "${FAKEROOT_DIR}/usr/local/lib/kernel/libfirehose_kernel.a"
    fi
}

build_xnu() {
    if [ ! -f "${BUILD_DIR}/xnu.obj/kernel.${KERNEL_TYPE}" ]; then
        if [ "$JSONDB" -ne "0" ]; then
            running "📦 Building XNU kernel with JSON compilation database"
            if [ ! -d "${KDKROOT}" ]; then
                error "KDKROOT not found: ${KDKROOT} - please install from the Developer Portal"
                exit 1
            fi
            SRCROOT="${WORK_DIR}/xnu"
            OBJROOT="${BUILD_DIR}/xnu-compiledb.obj"
            SYMROOT="${BUILD_DIR}/xnu-compiledb.sym"
            rm -rf "${OBJROOT}"
            rm -rf "${SYMROOT}"
            cd "${SRCROOT}"
            make SDKROOT=macosx TARGET_CONFIGS="$KERNEL_CONFIG $ARCH_CONFIG $MACHINE_CONFIG" LOGCOLORS=y BUILD_WERROR=0 BUILD_LTO=0 BUILD_JSON_COMPILATION_DATABASE=1 SRCROOT="${SRCROOT}" OBJROOT="${OBJROOT}" SYMROOT="${SYMROOT}" DSTROOT="${DSTROOT}" FAKEROOT_DIR="${FAKEROOT_DIR}" KDKROOT="${KDKROOT}" TIGHTBEAMC=${TIGHTBEAMC} RC_DARWIN_KERNEL_VERSION=${RC_DARWIN_KERNEL_VERSION} || true
            JSON_COMPILE_DB="$(find "${OBJROOT}" -name compile_commands.json)"
            info "JSON compilation database: ${JSON_COMPILE_DB}"
            cp -f "${JSON_COMPILE_DB}" "${SRCROOT}"
            mkdir -p "${CACHE_DIR}/${MACOS_VERSION}"
            info "Caching JSON compilation database in: ${CACHE_DIR}/${MACOS_VERSION}"
            cp -f "${JSON_COMPILE_DB}" "${CACHE_DIR}/${MACOS_VERSION}"
        else
            running "📦 Building XNU kernel TARGET_CONFIGS=\"$KERNEL_CONFIG $ARCH_CONFIG $MACHINE_CONFIG\""
            if [ ! -d "${KDKROOT}" ]; then
                error "KDKROOT not found: ${KDKROOT} - please install from the Developer Portal"
                exit 1
            fi
            SRCROOT="${WORK_DIR}/xnu"
            OBJROOT="${BUILD_DIR}/xnu.obj"
            SYMROOT="${BUILD_DIR}/xnu.sym"
            cd "${SRCROOT}"
            make install -j8 VERBOSE=YES SDKROOT=macosx TARGET_CONFIGS="$KERNEL_CONFIG $ARCH_CONFIG $MACHINE_CONFIG" CONCISE=0 LOGCOLORS=y BUILD_WERROR=0 BUILD_LTO=0 SRCROOT="${SRCROOT}" OBJROOT="${OBJROOT}" SYMROOT="${SYMROOT}" DSTROOT="${DSTROOT}" FAKEROOT_DIR="${FAKEROOT_DIR}" KDKROOT="${KDKROOT}" TIGHTBEAMC=${TIGHTBEAMC} RC_DARWIN_KERNEL_VERSION=${RC_DARWIN_KERNEL_VERSION}
            cd "${WORK_DIR}"
        fi
    else
        info "📦 XNU kernel.${KERNEL_TYPE} already built"
    fi
}

version_lte() {
    [ "$1" = "$(echo -e "$1\n$2" | sort -V | head -n1)" ]
}

version_lt() {
    [ "$1" = "$2" ] && return 1 || version_lte "$1" "$2"
}

build_kc() {
    if [ -f "${BUILD_DIR}/xnu.obj/kernel.${KERNEL_TYPE}" ]; then
        running "📦 Building kernel collection for kernel.${KERNEL_TYPE}"
        KDK_FLAG=""
        if version_lte 13.0 "$(sw_vers -productVersion | grep -Eo '[0-9]+\.[0-9]+')"; then
            KDK_FLAG="--kdk ${KDKROOT}" # Newer versions of kmutil support the --kdk option
        fi
        if [ "$ARCH_CONFIG" == "ARM64" ]; then
            kmutil create -v -V "${KC_VARIANT}" -a arm64e -n boot -s none \
                ${KDK_FLAG} \
                -B "${DSTROOT}/oss-xnu.macOS.${MACOS_VERSION}.kc.$(echo "$MACHINE_CONFIG" | tr '[:upper:]' '[:lower:]')" \
                -k "${BUILD_DIR}/xnu.obj/kernel.${KERNEL_TYPE}" \
                -x $(ipsw kernel kmutil inspect -x --filter "${KC_FILTER}") # this will skip KC_FILTER regex (and other KEXTs with them as dependencies)
                # -x $(kmutil inspect -V release --no-header | grep apple | grep -v "SEPHibernation" | awk '{print " -b "$1; }')
        else
            kmutil create -v -V "${KC_VARIANT}" -a x86_64 -n boot sys -s none \
                ${KDK_FLAG} \
                -B "${DSTROOT}/BootKernelExtensions.${MACOS_VERSION}.$(echo "$MACHINE_CONFIG" | tr '[:upper:]' '[:lower:]').kc" \
                -S "${DSTROOT}/SystemKernelExtensions.${MACOS_VERSION}.$(echo "$MACHINE_CONFIG" | tr '[:upper:]' '[:lower:]').kc" \
                -k "${BUILD_DIR}/xnu.obj/kernel.${KERNEL_TYPE}" \
                --elide-identifier com.apple.ExclaveKextClient \
                -x $(ipsw kernel kmutil inspect -x --filter "${KC_FILTER}") # this will skip KC_FILTER regex (and other KEXTs with them as dependencies)
                # -x $(kmutil inspect -V release --no-header | grep apple | grep -v "SEPHibernation" | awk '{print " -b "$1; }')
        fi
        echo "  🎉 KC Build Done!"
    fi
}

main() {
    # Parse arguments
    while test $# -gt 0; do
        case "$1" in
        -h | --help)
            help
            ;;
        --clean-partial)
            clean_partial
            shift
            exit 0
            ;;
        -c | --clean)
            clean
            shift
            exit 0
            ;;
        -k | --kc)
            BUILDKC=1
            shift
            ;;
        --kdk-dirs)
            KDK_DST_DIR="$2"
            shift
            shift
            ;;
        *)
            break
            ;;
        esac
    done
    echo "Installing dependencies" >> log.txt
    install_deps
    echo "Choosing XNU release" >> log.txt
    choose_xnu
    echo "Getting XNU sources" >> log.txt
    get_xnu
    echo "Applying patches" >> log.txt
    patches
    echo "Setting up virtual environment" >> log.txt
    venv
    echo "Building bootstrap commands" >> log.txt
    build_bootstrap_cmds
    echo "Building DTrace" >> log.txt
    build_dtrace
    echo "Building availablity versions" >> log.txt
    build_availabilityversions
    echo "Making XNU headers" >> log.txt
    xnu_headers
    echo "Making libsystem headers" >> log.txt
    libsystem_headers
    echo "Making libsyscalls headers" >> log.txt
    libsyscall_headers
    echo "Building libplatform" >> log.txt
    build_libplatform
    echo "Building libdispatch" >> log.txt
    build_libdispatch
    echo "Building XNU" >> log.txt
    build_xnu
    echo "Done" >> log.txt
    echo "  🎉 XNU Build Done!"
    if [ "$BUILDKC" -ne "0" ]; then
        echo "Installing IPSW" >> log.txt
        install_ipsw
        echo "Building kernelcache" >> log.txt
        build_kc
        echo "Done" >> log.txt
    fi
}

main "$@"
