#!/usr/bin/env bash
# ===================================================================================
# build_kernel_zip.sh
# Automated kernel build + flashable zip script for bone-machine's A52s 5G kernel
# Must be run from the kernel root directory (android_kernel_samsung_sm7325_a52s_5g/)
# ===================================================================================

set -euo pipefail

# ─── Colour helpers ───────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}${BOLD}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}${BOLD}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}${BOLD}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}${BOLD}[ERR]${NC}   $*" >&2; exit 1; }

# ─── Trap: clean up any mktemp dirs on unexpected exit ────────────────────────
TMP_CLANG=""
TMP_MAGISK=""
cleanup_tmp() {
    [[ -n "$TMP_CLANG"  && -d "$TMP_CLANG"  ]] && rm -rf "$TMP_CLANG"
    [[ -n "$TMP_MAGISK" && -d "$TMP_MAGISK" ]] && rm -rf "$TMP_MAGISK"
}
trap cleanup_tmp EXIT

# ─── Configuration ───────────────────────────────────────────────────────────
AUTHOR="bone-machine"
DEVICE="a52sxq"
DEFCONFIG="vendor/a52sxq_kor_single_defconfig"

# Nowy Clang wskazany przez użytkownika
CLANG_URL="https://github.com/danjekb/tools/releases/download/clang/main-clang-r530567.tar.gz"
CLANG_TAR="main-clang-r530567.tar.gz"

KERNEL_ROOT="$(pwd)"
TOOLCHAIN_DIR="${KERNEL_ROOT}/toolchain"
CLANG_DIR="${TOOLCHAIN_DIR}/clang"
OUT_DIR="${KERNEL_ROOT}/out"
FLAT_MODULES_DIR="${KERNEL_ROOT}/flat_modules"

# Paths to input base images (adjust if needed)
BASE_BOOT_IMG="${KERNEL_ROOT}/base_images/boot.img"
BASE_VENDOR_BOOT_IMG="${KERNEL_ROOT}/base_images/vendor_boot.img"
TSP_FW_DIR="${KERNEL_ROOT}/firmware/tsp"

# Template zip structure directory
TEMPLATE_ZIP_DIR="${KERNEL_ROOT}/nobootlag-template"
UPDATE_BINARY="${TEMPLATE_ZIP_DIR}/META-INF/com/google/android/update-binary"

# Determine branch and ROM type
BRANCH_NAME="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"
if [[ "$BRANCH_NAME" == *"oneui"* ]]; then
    ROM_TYPE="One-UI"
else
    ROM_TYPE="AOSP"
fi

# Detect KernelSU-Next version if available
if [[ -d "KernelSU-Next" ]]; then
    cd KernelSU-Next
    KSU_VER="$(git describe --tags --abbrev=0 2>/dev/null || git rev-parse --short HEAD 2>/dev/null || echo "Custom")"
    cd "${KERNEL_ROOT}"
    ROOT_DISPLAY="KernelSU-Next ${KSU_VER}"
else
    ROOT_DISPLAY="None"
fi

BUILD_DATE="$(date +'%Y%m%d')"
ZIP_NAME="${AUTHOR}_${BUILD_DATE}_${ROM_TYPE}_KSU-Next_a52sxq.zip"

# ─── Step 1: Pre-flight checks ───────────────────────────────────────────────
info "Starting pre-flight validation..."
[[ -f "Makefile" ]] || die "Not in kernel root directory (Makefile missing)."

# Verify required host tools
for tool in curl unzip cpio depmod git tar; do
    command -v "$tool" &>/dev/null || die "Missing required host tool: $tool"
done

# Verify inputs exist
[[ -f "arch/arm64/configs/${DEFCONFIG}" ]] || die "Defconfig missing: ${DEFCONFIG}"

# Ensure submodules are active
if [[ -d "KernelSU-Next" ]]; then
    info "Initializing/updating submodules..."
    git submodule update --init --recursive
fi

# ─── Step 2: Set up custom Clang toolchain ───────────────────────────────────
if [[ -d "${CLANG_DIR}/bin" ]]; then
    info "Using existing Clang toolchain at ${CLANG_DIR}"
else
    info "Clang toolchain not found. Downloading custom r530567 from GitHub..."
    mkdir -p "${TOOLCHAIN_DIR}"
    TMP_CLANG="$(mktemp -d -p "${TOOLCHAIN_DIR}" .clang_download_XXXXXX)"
    
    info "Downloading archive..."
    curl -L "${CLANG_URL}" -o "${TMP_CLANG}/${CLANG_TAR}" || die "Failed to download Clang archive"
    
    info "Extracting archive..."
    tar -xf "${TMP_CLANG}/${CLANG_TAR}" -C "${TMP_CLANG}" || die "Failed to untar Clang"
    
    # Przeniesienie wypakowanej zawartości (obsługa struktury katalogu wewnątrz paczki)
    # Paczka może zawierać podkatalog (np. 'main-clang-r530567' lub direkt bin). Sprawdzamy to:
    if [[ -d "${TMP_CLANG}/bin" ]]; then
        mv "${TMP_CLANG}" "${CLANG_DIR}"
    else
        # Znajdź pierwszy podkatalog, który zawiera folder 'bin'
        SUB_DIR="$(find "${TMP_CLANG}" -maxdepth 2 -type d -name "bin" -exec dirname {} \; | head -n 1)"
        if [[ -n "$SUB_DIR" && -d "$SUB_DIR" ]]; then
            mv "$SUB_DIR" "${CLANG_DIR}"
        else
            die "Could not locate bin/ directory inside extracted Clang tarball"
        fi
    fi
    success "Clang toolchain deployed successfully to ${CLANG_DIR}"
fi

# Verify compiler binaries
export PATH="${CLANG_DIR}/bin:${PATH}"
command -v clang &>/dev/null || die "clang binary not functional or missing in PATH"
command -v ld.lld &>/dev/null || die "ld.lld binary not functional or missing in PATH"
command -v llvm-strip &>/dev/null || die "llvm-strip binary not functional or missing in PATH"

# ─── Step 3: Set up magiskboot ───────────────────────────────────────────────
MAGISKBOOT="${TOOLCHAIN_DIR}/magiskboot"
if [[ -f "$MAGISKBOOT" ]]; then
    info "Using existing magiskboot binary"
else
    info "Magiskboot not found. Fetching from official Magisk APK..."
    TMP_MAGISK="$(mktemp -d -p "${TOOLCHAIN_DIR}" .magisk_download_XXXXXX)"
    
    # Fetch latest stable Magisk APK metadata and download it
    MAGISK_APK_URL=$(curl -s https://api.github.com/repos/topjohnwu/Magisk/releases/latest | grep "browser_download_url.*Magisk-v.*apk" | head -n 1 | cut -d '"' -f 4)
    [[ -n "$MAGISK_APK_URL" ]] || MAGISK_APK_URL="https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk"
    
    curl -L "$MAGISK_APK_URL" -o "${TMP_MAGISK}/magisk.apk" || die "Failed to download Magisk APK"
    unzip -q "${TMP_MAGISK}/magisk.apk" -d "${TMP_MAGISK}/extracted" || die "Failed to unzip Magisk APK"
    
    # Identify host architecture to pull correct binary
    HOST_ARCH="$(uname -m)"
    case "$HOST_ARCH" in
        x86_64)  ARCH_DIR="x86_64" ;;
        x86|i686) ARCH_DIR="x86" ;;
        aarch64) ARCH_DIR="arm64-v8a" ;;
        *)       die "Unsupported build host architecture: ${HOST_ARCH}" ;;
    esac
    
    TARGET_SO="${TMP_MAGISK}/extracted/lib/${ARCH_DIR}/libmagiskboot.so"
    [[ -f "$TARGET_SO" ]] || die "Could not locate libmagiskboot.so for ${HOST_ARCH}"
    
    cp "$TARGET_SO" "$MAGISKBOOT"
    chmod +x "$MAGISKBOOT"
    success "Magiskboot configured successfully"
fi

# ─── Step 4: Clean & Defconfig ───────────────────────────────────────────────
info "Cleaning previous build outputs..."
rm -rf "$OUT_DIR" "$FLAT_MODULES_DIR"
mkdir -p "$OUT_DIR" "$FLAT_MODULES_DIR"

info "Generating .config using ${DEFCONFIG}..."
make O="$OUT_DIR" ARCH=arm64 "$DEFCONFIG" || die "make defconfig failed"

# ─── Step 5: Compile Kernel ──────────────────────────────────────────────────
info "Compiling kernel jądra (using $(nproc) threads)..."
make O="$OUT_DIR" \
     ARCH=arm64 \
     LLVM=1 \
     LLVM_IAS=1 \
     CROSS_COMPILE=aarch64-linux-gnu- \
     CROSS_COMPILE_ARM32=arm-linux-gnueabi- \
     -j"$(nproc)" || die "Kernel compilation failed"

success "Kernel binary successfully built!"

# ─── Step 6: Process Modules & Dependencies ──────────────────────────────────
info "Installing and stripping modules..."
make O="$OUT_DIR" \
     ARCH=arm64 \
     LLVM=1 \
     LLVM_IAS=1 \
     INSTALL_MOD_PATH="${OUT_DIR}/modules_stage" \
     INSTALL_MOD_STRIP=1 \
     modules_install || die "Modules installation/strip failed"

info "Gathering flat modules and computing dependencies..."
find "${OUT_DIR}/modules_stage" -type f -name "*.ko" -exec cp {} "${FLAT_MODULES_DIR}/" \;

# Run depmod relative to the system map
depmod -b "${OUT_DIR}/modules_stage" -F "${OUT_DIR}/System.map" 5.4.254 || true

# Extract core dependency configuration maps
STAGE_LIB_DIR="${OUT_DIR}/modules_stage/lib/modules/5.4.254"
if [[ -d "$STAGE_LIB_DIR" ]]; then
    cp "${STAGE_LIB_DIR}"/modules.{dep,alias,softdep} "${FLAT_MODULES_DIR}/" 2>/dev/null || true
    if [[ -f "${STAGE_LIB_DIR}/modules.order" ]]; then
        awk -F'/' '{print $nf}' "${STAGE_LIB_DIR}/modules.order" > "${FLAT_MODULES_DIR}/modules.load"
    fi
else
    warn "Stage library directory not found; dependency maps might be incomplete."
fi
success "Modules processing complete"

# ─── Step 7: Re-pack boot.img ────────────────────────────────────────────────
info "Repacking boot.img..."
[[ -f "$BASE_BOOT_IMG" ]] || die "Base boot.img missing at ${BASE_BOOT_IMG}"
[[ -f "${OUT_DIR}/arch/arm64/boot/Image" ]] || die "Built kernel Image file missing"

TMP_BOOT_DIR="$(mktemp -d)"
cd "$TMP_BOOT_DIR"
cp "$BASE_BOOT_IMG" ./boot.img
"$MAGISKBOOT" unpack boot.img || die "Failed to unpack boot.img"
cp -f "${OUT_DIR}/arch/arm64/boot/Image" ./kernel
"$MAGISKBOOT" repack boot.img || die "Failed to repack boot.img"

mkdir -p "${TEMPLATE_ZIP_DIR}/images"
cp -f new-boot.img "${TEMPLATE_ZIP_DIR}/images/boot.img"
cd "${KERNEL_ROOT}"
rm -rf "$TMP_BOOT_DIR"
success "boot.img repacked into template"

# ─── Step 8: Stage dtbo.img ──────────────────────────────────────────────────
info "Staging dtbo.img..."
[[ -f "${OUT_DIR}/arch/arm64/boot/dtbo.img" ]] || die "Built dtbo.img missing"
cp -f "${OUT_DIR}/arch/arm64/boot/dtbo.img" "${TEMPLATE_ZIP_DIR}/images/dtbo.img"
success "dtbo.img staged into template"

# ─── Step 9: Re-pack vendor_boot.img ─────────────────────────────────────────
info "Repacking vendor_boot.img..."
[[ -f "$BASE_VENDOR_BOOT_IMG" ]] || die "Base vendor_boot.img missing at ${BASE_VENDOR_BOOT_IMG}"

TMP_VBOOT_DIR="$(mktemp -d)"
cd "$TMP_VBOOT_DIR"
cp "$BASE_VENDOR_BOOT_IMG" ./vendor_boot.img
"$MAGISKBOOT" unpack vendor_boot.img || die "Failed to unpack vendor_boot.img"

# Update base device tree binary if generated
if [[ -f "${OUT_DIR}/arch/arm64/boot/dts/vendor/qcom/yupik.dtb" ]]; then
    cp -f "${OUT_DIR}/arch/arm64/boot/dts/vendor/qcom/yupik.dtb" ./dtb
fi

# Inject custom header signature identifier to override board check bounds safely
# Hex modification for specific board parameter string "name=SRPUE26A001"
sed -i 's/name=/name=SRPUE26A001/g' ./header 2>/dev/null || true

# Extract vendor ramdisk cpio archive
mkdir ramdisk_root
cd ramdisk_root
cpio -idu < ../ramdisk.cpio 2>/dev/null || true

# Inject compiled modules and runtime maps cleanly into the ramdisk tree
# Clean outdated configurations first safely
find lib/modules/ -type f -name "*.ko" -delete 2>/dev/null || true
rm -rf lib/modules/*-gki/ 2>/dev/null || true

mkdir -p lib/modules
cp -f "${FLAT_MODULES_DIR}"/* lib/modules/ 2>/dev/null || true

# Inject touchscreen firmware files if locally present
if [[ -d "$TSP_FW_DIR" ]]; then
    mkdir -p lib/firmware
    find "$TSP_FW_DIR" -type f -name "fts5cu56a_a52sxq*" -exec cp {} lib/firmware/ \;
fi

# Enforce uniform permission schemas inside structural node points safely
find lib/modules -type d -exec chmod 755 {} \; 2>/dev/null || true
find lib/modules -type f -exec chmod 644 {} \; 2>/dev/null || true
if [[ -d "lib/firmware" ]]; then
    find lib/firmware -type d -exec chmod 755 {} \; 2>/dev/null || true
    find lib/firmware -type f -exec chmod 644 {} \; 2>/dev/null || true
fi

# Repack the modified structural components back into a sealed dynamic archive
find . -mindepth 1 | cpio -H newc -o > ../ramdisk.cpio 2>/dev/null || die "cpio ramdisk pack failed"
cd ..

# Compress and rebuild the updated full operational block structure container image
"$MAGISKBOOT" repack vendor_boot.img || die "Failed to repack vendor_boot.img"
cp -f new-vendor_boot.img "${TEMPLATE_ZIP_DIR}/images/vendor_boot.img"

cd "${KERNEL_ROOT}"
rm -rf "$TMP_VBOOT_DIR"
success "vendor_boot.img repacked into template"

# ─── Step 12: Patch Installer UI Scripts ─────────────────────────────────────
info "Injecting build variables into update-binary script..."
[[ -f "$UPDATE_BINARY" ]] || die "Installer script missing at ${UPDATE_BINARY}"

DATE_ESC=$(echo "${BUILD_DATE}" | sed 's/[&/]/\\&/g')
ROM_ESC=$(echo "${ROM_TYPE}" | sed 's/[&/]/\\&/g')
ROOT_ESC=$(echo "${ROOT_DISPLAY}" | sed 's/[&/]/\\&/g')

sed -i "s|^ui_print \"ROM:        .*\";$|ui_print \"ROM:        ${ROM_ESC}\";|" \
    "$UPDATE_BINARY" || die "sed patch of update-binary ROM failed"
sed -i "s|^ui_print \"Root:       .*\";$|ui_print \"Root:       ${ROOT_ESC}\";|" \
    "$UPDATE_BINARY" || die "sed patch of update-binary Root failed"
sed -i "s|^ui_print \"Build date: .*\";$|ui_print \"Build date: ${DATE_ESC}\";|" \
    "$UPDATE_BINARY" || die "sed patch of update-binary failed"

# Verify the patches actually landed
grep -Fq "ROM:        ${ROM_TYPE}"     "$UPDATE_BINARY" || die "update-binary ROM patch did not apply"
grep -Fq "Root:       ${ROOT_DISPLAY}" "$UPDATE_BINARY" || die "update-binary Root patch did not apply"
grep -Fq "Build date: ${BUILD_DATE}"   "$UPDATE_BINARY" || die "update-binary Build date patch did not apply"
success "update-binary patched and verified"

# ─── Step 13: Make flashable zip ─────────────────────────────────────────────
info "Creating flashable zip: ${ZIP_NAME}..."
[[ ! -f "${KERNEL_ROOT}/${ZIP_NAME}" ]] || warn "Overwriting existing zip: ${ZIP_NAME}"
cd "${TEMPLATE_ZIP_DIR}" || die "Missing ${TEMPLATE_ZIP_DIR}"
zip -X -r -9 "${KERNEL_ROOT}/${ZIP_NAME}" META-INF/ images/ \
    || die "zip creation failed"
cd "${KERNEL_ROOT}"
success "Flashable zip created: ${KERNEL_ROOT}/${ZIP_NAME}"

# ─── Done ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  Build complete!${NC}"
echo -e "  Author:     ${AUTHOR}"
echo -e "  Device:     ${DEVICE}"
echo -e "  ROM Type:   ${ROM_TYPE}"
echo -e "  Root:       ${ROOT_DISPLAY}"
echo -e "  Output:     ${ZIP_NAME}"
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════${NC}"
echo ""
