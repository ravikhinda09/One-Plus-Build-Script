#!/bin/bash
set -euo pipefail

##############################
# ===== INPUTS ===== #
##############################
MODEL="OP-ACE-5"
SOC="sm8650"
BRANCH="oneplus/sm8650"
MANIFEST="oneplus_ace5_b.xml"
KSUN_BRANCH="stable"
RE_BRANCH="main"
UNAME="OP-Blast"
SUSFS_INPUT="f6255b5f0f7a64b9d1eb03f71dd32aaa603dddee"
OPTIMIZE="O2"
##############################

# ===== SELECTION MENU =====
echo "=============================="
echo "  SELECT ROOT TYPE"
echo "=============================="
echo "1) KernelSU-Next"
echo "2) ReSukiSU"
read -p "Enter choice [1-2]: " CHOICE
##############################

CONFIG="$MODEL"
WORKSPACE="$PWD"
CONFIG_DIR="$WORKSPACE/$CONFIG"
ARTIFACTS_DIR="$CONFIG_DIR/artifacts"
REPO="/usr/local/bin/repo"

echo "===== VALIDATE ====="
[ -z "$MODEL" ] && { echo "Empty model not allowed"; exit 1; }

echo "===== INSTALL DEPS ====="
sudo apt-get update -qq
sudo apt-get install -y git curl ca-certificates build-essential clang lld flex bison \
libelf-dev libssl-dev libncurses-dev zlib1g-dev liblz4-tool \
libxml2-utils rsync unzip dwarves file python3 zip

echo "===== SETUP ENV ====="
if [ ! -x "$REPO" ]; then
  sudo curl -s https://storage.googleapis.com/git-repo-downloads/repo -o "$REPO"
  sudo chmod +x "$REPO"
fi

mkdir -p "$CONFIG_DIR"
cd "$CONFIG_DIR"

echo "===== INIT + SYNC ====="
if [[ "$MANIFEST" == https://* ]]; then
  mkdir -p .repo/manifests
  curl -L "$MANIFEST" -o .repo/manifests/temp_manifest.xml
  $REPO init -u https://github.com/OnePlusOSS/kernel_manifest.git -b oneplus/sm8650 -m temp_manifest.xml --depth=1
else
  $REPO init -u https://github.com/OnePlusOSS/kernel_manifest.git -b "$BRANCH" -m "$MANIFEST" --depth=1
fi

success=false
for i in 1 2 3; do
  if $REPO sync -c --no-clone-bundle --no-tags --optimized-fetch -j$(nproc) --fail-fast -v; then
    success=true
    break
  fi
  echo "repo sync attempt $i failed; retrying..."
  sleep 30
done
$success || { echo "repo sync failed after 3 attempts"; exit 1; }

echo "===== VERSION INFO ====="
mkdir -p "$ARTIFACTS_DIR"
cd "$CONFIG_DIR/kernel_platform/common"

CONFIG_FILES=("build.config.common" "build.config.constants")
BRANCH_LINE=""

for f in "${CONFIG_FILES[@]}"; do
  if [ -f "$f" ]; then
    l=$(grep '^[[:space:]]*BRANCH=' "$f" || true)
    if [ -n "$l" ]; then BRANCH_LINE="$l"; break; fi
  fi
done

[ -z "$BRANCH_LINE" ] && { echo "No BRANCH found"; exit 1; }

BRANCH_VALUE="${BRANCH_LINE#*=}"
ANDROID_VER="${BRANCH_VALUE%-*}"

VERSION=$(grep '^VERSION *=' Makefile | awk '{print $3}')
PATCHLEVEL=$(grep '^PATCHLEVEL *=' Makefile | awk '{print $3}')
SUBLEVEL=$(grep '^SUBLEVEL *=' Makefile | awk '{print $3}')

FULL_VERSION="$VERSION.$PATCHLEVEL.$SUBLEVEL"
KERNEL_FULL_VER="$ANDROID_VER-$FULL_VERSION"
SUSFS_KERNEL_BRANCH="gki-$ANDROID_VER-$VERSION.$PATCHLEVEL"

echo "$KERNEL_FULL_VER" > "$ARTIFACTS_DIR/${MODEL}.txt"

cd "$CONFIG_DIR"

echo "===== CLONE DEPENDENCIES ====="
ANYKERNEL_BRANCH="gki-2.0"

if [[ -z "$SUSFS_INPUT" ]]; then
  SUSFS_BRANCH="$SUSFS_KERNEL_BRANCH"
else
  SUSFS_BRANCH="$SUSFS_INPUT"
fi

if [ ! -d "$CONFIG_DIR/AnyKernel3" ]; then
  echo "Cloning AnyKernel3."
git clone --depth=1 https://github.com/TheWildJames/AnyKernel3.git -b "$ANYKERNEL_BRANCH"
else
  echo "AnyKernel folder Already exist."
fi

if [ ! -d "$CONFIG_DIR/kernel_patches" ]; then
  echo "Cloning kernel_patches."
git clone --depth=1 https://github.com/TheWildJames/kernel_patches.git
else
  echo "kernel_patches folder Already exist."
fi

if [ ! -d "$CONFIG_DIR/susfs4ksu" ]; then
    echo "🔍 Cloning susfs4ksu and checking out specific commit..."
    mkdir -p "$CONFIG_DIR/susfs4ksu"
    cd "$CONFIG_DIR/susfs4ksu"
    
    git init -q
    git remote add origin https://gitlab.com/simonpunk/susfs4ksu.git
    
    # Hum seedha us hash ko fetch karenge jo tune top par diya hai
    if git fetch --depth 1 origin "$SUSFS_BRANCH"; then
        git checkout -q FETCH_HEAD
        echo "✅ Success: susfs4ksu synced at commit ${SUSFS_BRANCH:0:8}"
    else
        echo "❌ Error: Could not fetch commit hash $SUSFS_BRANCH"
        exit 1
    fi
    cd "$CONFIG_DIR"
else
    echo "✅ susfs4ksu folder already exists."
fi

cd susfs4ksu
git checkout "$SUSFS_BRANCH" || { echo "Invalid SUSFS ref"; exit 1; }

echo "===== CLEAN ABI ====="
cd "$CONFIG_DIR/kernel_platform"
rm -f common/android/abi_gki_protected_exports_* || true
rm -f msm-kernel/android/abi_gki_protected_exports_* || true

echo "===== ADD ROOT SYSTEM ====="
cd "$CONFIG_DIR/kernel_platform"

if [ "$CHOICE" == "1" ]; then
    echo "Adding KernelSU Next..."
    KSUN_INPUT="$KSUN_BRANCH"
    if [ -z "$KSUN_INPUT" ]; then
      curl --fail --location --proto '=https' -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh" | bash -
    else
      curl --fail --location --proto '=https' -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh" | bash -s "$KSUN_INPUT"
    fi
    
    git submodule update --init --recursive
    KSU_FOLDER_NAME="KernelSU-Next"
    
    # KernelSU-Next Version Logic (As it was)
    cd "$KSU_FOLDER_NAME/kernel"
    COMMITS_COUNT=$(git rev-list --count HEAD)
    BASE_VERSION=$([ "$COMMITS_COUNT" -lt 2684 ] && echo 10200 || echo 30000)
    KSU_VERSION=$((COMMITS_COUNT + BASE_VERSION))
    echo "KSU Next Version: $KSU_VERSION"
    sed -i "s/DKSU_VERSION=.*/DKSU_VERSION=${KSU_VERSION}/" Makefile
    
    if [ -f ksu.c ]; then
      sed -i 's/#if defined(CONFIG_STACKPROTECTOR).*/#if 0/' ksu.c
    fi
    cd ../..

else
    # ============================================================
    # ADD RESUKISU (EXACTLY AS PER WORKFLOW)
    # ============================================================
    echo "Adding ReSukiSU..."
    
    # Workflow style installation
    KSU_INPUT="$RE_BRANCH" # hash or branch
    if [ "$KSU_INPUT" = "" ]; then
      curl --fail --location --proto '=https' -LSs "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh" | bash -
    else
      curl --fail --location --proto '=https' -LSs "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh" | bash -s "$KSU_INPUT"
    fi
    
    KSU_FOLDER_NAME="KernelSU"
    cd "$KSU_FOLDER_NAME"
    
    # Workflow Version Logic
    BASE_VERSION=30700
    KSU_VERSION=$(expr $(/usr/bin/git rev-list --count HEAD) "+" $BASE_VERSION)
    KSU_COMMIT_SHA=$(git rev-parse HEAD)
    
    echo "ReSukiSU Version: $KSU_VERSION"
    echo "✅ ReSukiSU added (commit: ${KSU_COMMIT_SHA:0:8})"
    
    cd ..
    # ============================================================
fi

echo "===== SUSFS PATCHING SECTION ====="
SUSFS_FOLDER="$CONFIG_DIR/susfs4ksu"
COMMON_KERNEL_FOLDER="$CONFIG_DIR/kernel_platform/common"
KERNEL_PATCHES_FOLDER="$CONFIG_DIR/kernel_patches"
KSUN_FOLDER="$CONFIG_DIR/kernel_platform/$KSU_FOLDER_NAME"

# 1. Copy SUSFS base files (Dono ke liye)
echo "Copying SUSFS base files..."
cp "$SUSFS_FOLDER/kernel_patches/fs/"* "$COMMON_KERNEL_FOLDER/fs/"
cp "$SUSFS_FOLDER/kernel_patches/include/linux/"* "$COMMON_KERNEL_FOLDER/include/linux/"
susfs_version=$(grep '#define SUSFS_VERSION' "$COMMON_KERNEL_FOLDER/include/linux/susfs.h" | awk -F'"' '{print $2}')

# -------------------------------------------------------------------------
# KSUN ONLY BLOCK: Ye patches ReSukiSU (Choice 2) mein skip honge
# -------------------------------------------------------------------------
if [ "$CHOICE" == "1" ]; then
    cd "$KSUN_FOLDER"
    echo "Applying KernelSU-Next Specific Patches..."
    yes "" | patch -p1 --forward < "$SUSFS_FOLDER/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch" || true

    echo "Fixing rejected patches for KSUN..."
    for file in $(find ./kernel -maxdepth 2 -name "*.rej" -exec basename {} .rej \;); do
        FIX_1="$KERNEL_PATCHES_FOLDER/next/susfs_fix_patches/$susfs_version/fix_$file.patch"
        FIX_2="$KERNEL_PATCHES_FOLDER/next/susfs_fix_patches/$susfs_version/fix_$file.c.patch"
        [ -f "$FIX_1" ] && yes "" | patch -p1 --forward < "$FIX_1" || true
        [ -f "$FIX_2" ] && yes "" | patch -p1 --forward < "$FIX_2" || true
    done

    echo "Applying Essential Fixes for KSUN..."
    yes "" | patch -p1 --forward --batch --force < "$KERNEL_PATCHES_FOLDER/next/susfs_fix_patches/$susfs_version/overwrite_hook_mode.patch" || true
    yes "" | patch -p1 --forward --batch --force < "$KERNEL_PATCHES_FOLDER/next/susfs_fix_patches/$susfs_version/ksu_toolkit.patch" || true
    [ "$KSU_VERSION" -le 33095 ] && yes "" | patch -p1 --forward --batch --force < "$KERNEL_PATCHES_FOLDER/next/susfs_fix_patches/$susfs_version/multi_manager.patch" || true
fi

# -------------------------------------------------------------------------
# COMMON KERNEL FIXES (Dma-buf/Fake Patch/Main SUSFS) - Applied for BOTH
# -------------------------------------------------------------------------
cd "$COMMON_KERNEL_FOLDER"
fake_patched=0
if [ "$ANDROID_VER" = "android14" ] && [ "$VERSION.$PATCHLEVEL" = "6.1" ]; then
    if ! grep -qxF $'\tif (!vma_pages(vma))' ./fs/proc/task_mmu.c; then
        echo "Fake Patching task_mmu.c..."
        fake_patched=1
    fi
    if ! grep -qxF '#include <linux/dma-buf.h>' ./fs/proc/base.c; then
        echo "Adding missing dma-buf.h header..."
        sed -i '/#include <linux\/cpufreq_times.h>/a #include <linux\/dma-buf.h>' ./fs/proc/base.c
    fi
fi

echo "Applying Main SUSFS Patch (50_add_susfs)..."
yes "" | patch -p1 --forward < "$SUSFS_FOLDER/kernel_patches/50_add_susfs_in_${SUSFS_KERNEL_BRANCH}.patch" || true

if [ "$fake_patched" = 1 ]; then
    sed -i -e 's/goto show_pad;/return 0;/' ./fs/proc/task_mmu.c || true
fi

cd "$CONFIG_DIR"
echo "✅ $KSU_FOLDER_NAME + SUSFS Patches applied successfully"

echo "===== ADD CONFIG ====="
cd "$CONFIG_DIR/kernel_platform"
cat >> common/arch/arm64/configs/gki_defconfig <<EOF
CONFIG_LTO_CLANG_THIN=y
CONFIG_LTO_CLANG=y
CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE=y
CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE_O3=n
CONFIG_OPTIMIZE_INLINING=y
CONFIG_KSU=y
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SUS_OVERLAYFS=n
CONFIG_KSU_SUSFS_TRY_UMOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_SUS_MAP=y
CONFIG_KSU_SUSFS_SUS_SU=n
EOF

echo "===== BRANDING ====="
CUSTOM_LOCALVERSION="-$ANDROID_VER-$UNAME"

echo "===== DETECT CLANG ====="
KP="$CONFIG_DIR/kernel_platform"
CLANG_FOUND=false

for base in "$KP/prebuilts" "$KP/prebuilts-master"; do
  [ -d "$base/clang/host/linux-x86" ] || continue
  latest=$(ls -d "$base"/clang/host/linux-x86/clang-r*/ 2>/dev/null | sort -V | tail -n1)
  if [ -n "$latest" ] && [ -x "$latest/bin/clang" ]; then
    CLANG_BIN="$latest/bin"
    CLANG_FOUND=true
  fi
done

if ! $CLANG_FOUND && command -v clang >/dev/null; then
  CLANG_BIN=$(dirname $(command -v clang))
  CLANG_FOUND=true
fi

$CLANG_FOUND || { echo "No clang found"; exit 1; }

CLANG_VERSION="$($CLANG_BIN/clang --version | head -n1)"
echo "Using clang: $CLANG_VERSION"

echo "===== BUILD ====="
cd "$KP/common"

: > .scmversion

export PATH="$CLANG_BIN:$PATH"
export LLVM=1 LLVM_IAS=1
export ARCH=arm64 SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export LD=ld.lld HOSTLD=ld.lld AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip HOSTCC=clang HOSTCXX=clang++
export CC=clang

OUT=out
mkdir -p "$OUT"

make O="$OUT" gki_defconfig

scripts/config --file "$OUT/.config" --set-str LOCALVERSION "$CUSTOM_LOCALVERSION"
scripts/config --file "$OUT/.config" -d LOCALVERSION_AUTO || true
sed -i 's/scm_version="$(scm_version --short)"/scm_version=""/' scripts/setlocalversion

if [ "$OPTIMIZE" = "O3" ]; then
  scripts/config --file "$OUT/.config" -d CC_OPTIMIZE_FOR_PERFORMANCE
  scripts/config --file "$OUT/.config" -e CC_OPTIMIZE_FOR_PERFORMANCE_O3
  export KCFLAGS="-Wno-error -pipe -O3 -fno-stack-protector"
else
  scripts/config --file "$OUT/.config" -e CC_OPTIMIZE_FOR_PERFORMANCE
  scripts/config --file "$OUT/.config" -d CC_OPTIMIZE_FOR_PERFORMANCE_O3
  export KCFLAGS="-Wno-error -pipe -O2 -fno-stack-protector"
fi

export KCPPFLAGS="-DCONFIG_OPTIMIZE_INLINING"

make O="$OUT" olddefconfig
make -j$(nproc) O="$OUT" 2>&1 | tee build.log

IMG="$OUT/arch/arm64/boot/Image"
[ ! -f "$IMG" ] && { echo "Kernel Image missing"; exit 1; }

sha256sum "$IMG" | tee "$OUT/Image.sha256"

echo "===== STATS ====="
WARNINGS=$(grep -i warning build.log | wc -l || true)
KERNEL_UNAME=$(strings "$IMG" | grep "Linux version" | tail -n1)
SHA=$(cut -d' ' -f1 "$OUT/Image.sha256")

echo "Kernel: $KERNEL_UNAME"
echo "Warnings: $WARNINGS"
echo "SHA256: $SHA"

sed -i 's/do.check_boot_version=0/do.check_boot_version=1/' "$CONFIG_DIR/AnyKernel3/anykernel.sh"

echo "===== ZIP ====="
cp "$IMG" "$CONFIG_DIR/AnyKernel3/Image"
cd "$CONFIG_DIR/AnyKernel3"

ZIP_NAME="AnyKernel3_${MODEL}_${KERNEL_FULL_VER}.zip"
mkdir -p "$ARTIFACTS_DIR"

zip -r "$ARTIFACTS_DIR/$ZIP_NAME" ./* >/dev/null

echo "OUTPUT: $ARTIFACTS_DIR/$ZIP_NAME"

echo "===== BUILD COMPLETED SUCCESSFULLY✅ ====="
