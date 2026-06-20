#!/bin/bash
set -euo pipefail

FILE="$(basename "$0")"

CONFIG_PATH="/etc/config.makepkg"
DEST_CONFIG_PATH="/etc/makepkg.conf.d"

custom_=0

y_val=("y" "Y" "Yes" "yes")

llvm_toolchain=()

REPLACE_AUR_HELPER=$INPUT_AURHELPER
BUILD_AUR_PACKAGE=$INPUT_BUILDAURHELPER

AUR_HELPER="paru"
AUR_HELPER_ARGS="$INPUT_AURARGS"

if [ -n "$INPUT_AURHELPER" ]; then
    AUR_HELPER="$REPLACE_AUR_HELPER"
fi 

pacman -Syyu --noconfirm archlinux-keyring reflector pacman-mirrorlist
pacman-key --init
pacman-key --populate
# reflector --threads 10 -l 10 --delay 0.25 -f 10 --sort rate --save /etc/pacman.d/mirrorlist

# Enable Chaotic AUR
if [ -n "$INPUT_CHAOTICAUR" ]; then
    pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com
    pacman-key --lsign-key 3056513887B78AEB
    pacman --noconfirm -U 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst'
    pacman --noconfirm -U 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst'
    sed -i -e '$a [chaotic-aur]' -e '$a Include = /etc/pacman.d/chaotic-mirrorlist' /etc/pacman.conf
fi


pacman -Syu --noconfirm base-devel wayland-protocols pacman-contrib pipewire wget pkgconf ninja meson git

if [ -n "$INPUT_MAXJOBS" ]; then
	echo "Set Max Jobs to $INPUT_MAXJOBS"
    sed -i "s/_max_jobs=\"\"/_max_jobs=\"$INPUT_MAXJOBS\"/" "$CONFIG_PATH/param.conf"
fi

if [ -n "$INPUT_CFLAGS" ]; then
	echo "Append $INPUT_CFLAGS to CFLAGS"
	sed -i "s/_custom_cflags=\"\"/_custom_cflags=\"$INPUT_CFLAGS\"/" $CONFIG_PATH/param.conf
fi

if [ -n "$INPUT_CUSTOMPACKAGES" ]; then
    echo "Installing $INPUT_CUSTOMPACKAGES"
    pacman -Sy --noconfirm $INPUT_CUSTOMPACKAGES
fi

if [ -n "$INPUT_CXXFLAGS" ]; then
	echo "Append $INPUT_CXXFLAGS to CXXFLAGS"
	sed -i "s/_custom_cxxflags=\"\"/_custom_cxxflags=\"$INPUT_CXXFLAGS\"/" $CONFIG_PATH/param.conf
fi

if [ -n "$INPUT_LDFLAGS" ]; then
	echo "Append $INPUT_LDFLAGS to LDFLAGS"
	sed -i "s/_custom_ldflags=\"\"/_custom_ldflags=\"$INPUT_LDFLAGS\"/" $CONFIG_PATH/param.conf
fi

if [ -n "$INPUT_RUSTCFLAGS" ]; then
	echo "Append $INPUT_RUSTCFLAGS to RUSTFLAGS"
	sed -i "s/_custom_rustc=\"\"/_custom_rustc=\"$INPUT_RUSTCFLAGS\"/" $CONFIG_PATH/param.conf
fi

if [ -n "$INPUT_EXTRAFLAGS" ]; then
	echo "Append $INPUT_EXTRAFLAGS to EXTRAFLAGS"
	sed -i "s/_extra_custom_flags=\"\"/_extra_custom_flags=\"$INPUT_EXTRAFLAGS\"/" $CONFIG_PATH/param.conf
fi

config="$(cat "$CONFIG_PATH/param.conf")"$'\n'

if [[ " ${y_val[@]} " =~ " $INPUT_CLANGED " ]]; then 
    printf "Switching to LLVM Toolchain \n"

    if [[ " ${y_val[@]} " =~ " $INPUT_OFFICIALREPO " ]]; then 
        printf "Use Arch Clang \n"
        llvm_toolchain=(clang llvm lld openmp compiler-rt polly)
    elif [[ " ${y_val[@]} " =~ " $INPUT_BOOTSTRAP " ]]; then
        printf "Use Bootstrap LLVM \n"
        llvm_toolchain=(llvm-bootstrap)
    else
        printf "Use Personal LLVM \n"
        llvm_toolchain=(llvm-all)
    fi

    pacman -Syu --noconfirm "${llvm_toolchain[@]}"

    # Set ld.lld as default linker
    ln -fs /usr/bin/ld.lld /usr/bin/ld

    # Replace gcc with clang as default compiler
    ln -fs /usr/bin/clang /usr/bin/gcc
    ln -fs /usr/bin/clang++ /usr/bin/g++

    config="${config}$(cat "$CONFIG_PATH/clang/compiler.conf")"$'\n'

    # Check for additional Clang flags
    if [[ " ${y_val[@]} " =~ " $INPUT_CLANGEDPFLAGS " ]]; then
        printf "Enabling Clang Extra flags\n"
        config="${config}$(cat "$CONFIG_PATH/clang/lld.conf")"$'\n'
        config="${config}$(cat "$CONFIG_PATH/clang/llvm.clang.conf")"$'\n'
        config="${config}$(cat "$CONFIG_PATH/clang/rust.llvm.conf")"$'\n'
    fi

    if [[ " ${y_val[@]} " =~ " $INPUT_CLANGEDPOLLY " ]]; then
        printf "Enabling Polly for Clang\n"
        config="${config}$(cat "$CONFIG_PATH/clang/polly.clang.conf")"$'\n'
    fi

    config="${config}$(cat "$CONFIG_PATH/clang/default.compiler.conf")"$'\n'
    config="${config}$(cat "$CONFIG_PATH/clang/flags.conf")"$'\n'
    custom_=1
fi

# Enable GCC Extra flags if specified
if [[ " ${y_val[@]} " =~ " $INPUT_GCCPFLAGS " ]] && [[ ! " ${y_val[@]} " =~ " $INPUT_CLANGED " ]]; then 
    
    pacman -Sy --noconfirm mold

    echo "Enabling GCC Extra flags"
    
    # Set ld.mold as default linker
    ln -fs /usr/bin/ld.mold /usr/bin/ld

    config="${config}$(cat "$CONFIG_PATH/gcc/config.conf")"$'\n'
    custom_=1
fi

if [[ $custom_ -eq 0 ]]; then 
    printf "Using Default Configuration \n"
    config="${config}$(cat "$CONFIG_PATH/flags.default.conf")"$'\n'
fi

config="${config}$(cat "$CONFIG_PATH/default.conf")"$'\n'

printf "%s" "$config" > "$DEST_CONFIG_PATH/config.conf" 

printf "======================= \n"
cat "$DEST_CONFIG_PATH/config.conf" 
printf "======================= \n"

printf "Finished configuring \n"

#force pod2man
ln -s /usr/bin/core_perl/pod2man /usr/bin/pod2man

# Makepkg does not allow running as root
# Create a new user `builder`
# `builder` needs to have a home directory because some PKGBUILDs will try to
# write to it (e.g. for cache)
if ! id -u builder &> /dev/null; then
    useradd builder -m
fi
# When installing dependencies, makepkg will use sudo
# Give user `builder` passwordless sudo access
echo "builder ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# Give all users (particularly builder) full access to these files
chmod -R 777 .

BASEDIR="$(pwd)"

if [[ " ${y_val[@]} " =~ " $BUILD_AUR_PACKAGE " ]]; then
    printf "Building aur helper $AUR_HELPER"
    pushd /tmp
    sudo -H -u builder git clone https://aur.archlinux.org/$AUR_HELPER.git
    cd $AUR_HELPER
    sudo -H -u builder makepkg -csi --noconfirm
    popd
    
    rm -rf /tmp/*
else
    printf "Use prebuild aur helper\n"
    pacman -Sy --noconfirm $AUR_HELPER
fi

if [ ! -d "$INPUT_PKGDIR" ]; then
    echo "Building from AUR..."
    sudo -H -u builder git clone "https://aur.archlinux.org/$INPUT_PKGDIR.git"
fi

cd "${INPUT_PKGDIR:-.}"
if grep -q "source" PKGBUILD; then
    sudo -H -u builder updpkgsums
fi

# Assume that if .SRCINFO is missing or mismatch
# Recreating .SRCINFO
echo "Creating .SRCINFO"
sudo -H -u builder makepkg --printsrcinfo > .SRCINFO

PKGVER="$(sed -n 's/^[[:space:]]*pkgver = \(.*\)[[:space:]]*$/\1/p' .SRCINFO | head -n1)"
PKGREL="$(sed -n 's/^[[:space:]]*pkgrel = \(.*\)[[:space:]]*$/\1/p' .SRCINFO | head -n1)"
EPOCH="$(sed -n 's/^[[:space:]]*epoch = \(.*\)[[:space:]]*$/\1/p' .SRCINFO | head -n1)"

EXPECTED_VERSION="${PKGVER}-${PKGREL}"
if [ -n "${EPOCH:-}" ] && [ "${EPOCH}" != "0" ]; then
    EXPECTED_VERSION="${EPOCH}:${EXPECTED_VERSION}"
fi

mapfile -t PKGNAMES < <(
  sed -n 's/^[[:space:]]*pkgname = \(.*\)[[:space:]]*$/\1/p' .SRCINFO | sort -u
)

if [ ${#PKGNAMES[@]} -gt 0 ] && [ -n "${PKGVER:-}" ] && [ -n "${PKGREL:-}" ]; then
    REPO_NAME="jp7-arch"
    echo "Package(s): ${PKGNAMES[*]}"
    echo "Expected version: $EXPECTED_VERSION"
    ALL_MATCH=1

    for PKGNAME in "${PKGNAMES[@]}"; do
        if PKGINFO="$(LC_ALL=C pacman -Si "${REPO_NAME}/${PKGNAME}" 2>/dev/null)"; then
            REMOTE_REPO="$(printf '%s\n' "$PKGINFO" | sed -n 's/^Repository[[:space:]]*:[[:space:]]*//p' | head -n1)"
            REMOTE_VERSION="$(printf '%s\n' "$PKGINFO" | sed -n 's/^Version[[:space:]]*:[[:space:]]*//p' | head -n1)"

            if [ "${REMOTE_REPO:-}" != "$REPO_NAME" ] || [ "${REMOTE_VERSION:-}" != "$EXPECTED_VERSION" ]; then
                ALL_MATCH=0
                break
            fi
        else
            ALL_MATCH=0
            break
        fi
    done

    if [ "$ALL_MATCH" -eq 1 ]; then
        echo "Package version already exists in $REPO_NAME (${PKGNAMES[*]} $EXPECTED_VERSION). Skipping build."
        exit 0
    fi
fi

# Extract AUR dependencies from .SRCINFO (depends or depends_x86_64) and install
mapfile -t NEEDED < <(
  sed -n -e 's/^[[:space:]]*\(make\)\?depends\(_x86_64\)\? = \([[:alnum:][:punct:]]*\)[[:space:]]*$/\3/p' .SRCINFO
)

if [ ${#NEEDED[@]} -eq 0 ]; then
  echo "No dependencies found."
else
  echo "Installing: ${NEEDED[@]}"
  mapfile -t PKGDEPS < <(sudo -H -u builder $AUR_HELPER -T "${NEEDED[@]}")

  if [[ "${NEEDED[*]}" == *"rust"* ]] || [[ "${NEEDED[*]}" == *"cargo"* ]]; then

      pacman -Sy --noconfirm rustup
      sudo -H -u builder rustup default stable
      sudo -H -u builder rustc --version

       mapfile -t PKGDEPS < <(sudo -H -u builder $AUR_HELPER -T "${NEEDED[@]}")
  fi

  sudo -H -u builder $AUR_HELPER $AUR_HELPER_ARGS -Sy --noconfirm --needed "${PKGDEPS[@]}"
fi

# Remove cache
rm -rf /var/cache/pacman/pkg/

# Make the builder user the owner of these files
# Without this, (e.g. only having every user have read/write access to the files), 
# makepkg will try to change the permissions of the files itself which will fail since it does not own the files/have permission
# we can't do this earlier as it will change files that are for github actions, which results in warnings in github actions logs.
chown -R builder .

# Build packages
# INPUT_MAKEPKGARGS is intentionally unquoted to allow arg splitting
# shellcheck disable=SC2086
sudo -H -u builder makepkg --syncdeps --noconfirm ${INPUT_MAKEPKGARGS:-}

# Get array of packages to be built
mapfile -t PKGFILES < <( sudo -u builder makepkg --packagelist )
echo "Package(s): ${PKGFILES[*]}"

# Report built package archives
i=0
for PKGFILE in "${PKGFILES[@]}"; do
    # makepkg reports absolute paths, must be relative for use by other actions
    RELPKGFILE="$(realpath --relative-base="$BASEDIR" "$PKGFILE")"
    # Caller arguments to makepkg may mean the package is not built
    if [ -f "$PKGFILE" ]; then
        echo "name=pkgfile$i::$RELPKGFILE" >> $GITHUB_OUTPUT
    else
        echo "Archive $RELPKGFILE not built"
    fi
    (( ++i ))
done

function prepend () {
    # Prepend the argument to each input line
    while read -r line; do
        echo "$1$line"
    done
}

function namcap_check() {
    # Run namcap checks
    # Installing namcap after building so that makepkg happens on a minimal
    # install where any missing dependencies can be caught.
    pacman -S --noconfirm --needed namcap

    NAMCAP_ARGS=()
    if [ -n "${INPUT_NAMCAPRULES:-}" ]; then
        NAMCAP_ARGS+=( "-r" "${INPUT_NAMCAPRULES}" )
    fi
    if [ -n "${INPUT_NAMCAPEXCLUDERULES:-}" ]; then
		NAMCAP_ARGS+=( "-e "${INPUT_NAMCAPDISABLE:-}"" "${INPUT_NAMCAPEXCLUDERULES}" )
    fi

    # For reasons that I don't understand, sudo is not resetting '$PATH'
    # As a result, namcap finds program paths in /usr/sbin instead of /usr/bin
    # which makes namcap fail to identify the packages that provide the
    # program and so it emits spurious warnings.
    # More details: https://bugs.archlinux.org/task/66430
    #
    # Work around this issue by putting bin ahead of sbin in $PATH
    export PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"

    namcap "${NAMCAP_ARGS[@]}" PKGBUILD \
        | prepend "::warning file=$FILE,line=$LINENO::"
    for PKGFILE in "${PKGFILES[@]}"; do
        if [ -f "$PKGFILE" ]; then
            RELPKGFILE="$(realpath --relative-base="$BASEDIR" "$PKGFILE")"
            namcap "${NAMCAP_ARGS[@]}" "$PKGFILE" \
                | prepend "::warning file=$FILE,line=$LINENO::$RELPKGFILE:"
        fi
    done
}

if [ -z "${INPUT_NAMCAPDISABLE:-}" ]; then
    namcap_check
fi
