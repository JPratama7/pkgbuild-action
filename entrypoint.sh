#!/bin/bash
set -euo pipefail

FILE="$(basename "$0")"

CONFIG_PATH="/etc/config.makepkg"
DEST_CONFIG_PATH="/etc/makepkg.conf.d/"

y_val=("y", "Y", "Yes", "yes")

llvm_toolchain=()

pacman -Syu --noconfirm yay wayland-protocols pacman-contrib pipewire wget pkgconf cmake ninja meson

cp $CONFIG_PATH/default.conf $DEST_CONFIG_PATH

if [[ ${y_val[@]} =~ $INPUT_CLANGED ]]; then 
    echo "Switching to LLVM Toolchain"

	if [[ ${y_val[@]} =~ $INPUT_OFFICIALREPO ]]; then 
		llvm_toolchain=(clang llvm lld openmp compiler-rt polly)
	elif [[ ${y_val[@]} =~ $INPUT_BOOTSTRAP ]]; then
		llvm_toolchain=(llvm-bootstrap)
	else
    	llvm_toolchain=(llvm-all)
	fi

	pacman -Syu --noconfirm  "${llvm_toolchain[@]}"

    # Set ld.lld as default linker
    ln -fs /usr/bin/ld.lld /usr/bin/ld
    ln -sf /usr/bin/ld.lld /usr/sbin/ld

    # Replace gcc with clang as default compiler
    ln -fs /usr/bin/clang /usr/bin/gcc
    ln -fs /usr/bin/clang++ /usr/bin/g++
    cp "$CONFIG_PATH/clang/compiler.conf" "$DEST_CONFIG_PATH"

    # Check for additional Clang flags
	if [[ ${y_val[@]} =~ $INPUT_CLANGEDPFLAGS ]]; then 
        printf "Enabling Clang Extra flags\n"
        cp "$CONFIG_PATH/clang/default.compiler.conf" "$DEST_CONFIG_PATH"
        cp "$CONFIG_PATH/clang/flags.conf" "$DEST_CONFIG_PATH"
        cp "$CONFIG_PATH/clang/llvm.clang.conf" "$DEST_CONFIG_PATH"
        cp "$CONFIG_PATH/clang/lld.conf" "$DEST_CONFIG_PATH"
        cp "$CONFIG_PATH/clang/rust.llvm.conf" "$DEST_CONFIG_PATH"
    fi
	if [[${y_val[@]} =~ $INPUT_CLANGEDPOLLY]]; then
		printf "Enabling Polly for Clang\n"
		cp "$CONFIG_PATH/clang/polly.clang.conf" "$DEST_CONFIG_PATH"
	fi 
fi

# Enable GCC Extra flags if specified
if [[ ${y_val[@]} =~ $INPUT_GCCPFLAGS ]] && [[ ! ${y_val[@]} =~ $INPUT_CLANGED ]]; then 
    echo "Enabling GCC Extra flags"
    cp "$CONFIG_PATH/gcc/config.conf" "$DEST_CONFIG_PATH"
fi

if [ -n "$INPUT_CFLAGS" ]; then
	echo "Append $INPUT_CFLAGS to CFLAGS"
	sed -i "s/_custom_cflags=\"\"/_custom_cflags=\"$INPUT_CFLAGS\"/" $DEST_CONFIG_PATH/default.conf
fi

if [ -n "$INPUT_CXXFLAGS" ]; then
	echo "Append $INPUT_CXXFLAGS to CFLAGS"
	sed -i "s/_custom_cxxflags=\"\"/_custom_cxxflags=\"$INPUT_CXXFLAGS\"/" $DEST_CONFIG_PATH/default.conf
fi

if [ -n "$INPUT_LDFLAGS" ]; then
	echo "Append $INPUT_LDFLAGS to CFLAGS"
	sed -i "s/_custom_ldflags=\"\"/_custom_ldflags=\"$INPUT_LDFLAGS\"/" $DEST_CONFIG_PATH/default.conf
fi

if [ -n "$INPUT_RUSTCFLAGS" ]; then
	echo "Append $INPUT_RUSTCFLAGS to CFLAGS"
	sed -i "s/_custom_rustc=\"\"/_custom_rustc=\"$INPUT_RUSTCFLAGS\"/" $DEST_CONFIG_PATH/default.conf
fi

printf "Finished cofiguring"

#force pod2man
ln -s /usr/bin/core_perl/pod2man /usr/bin/pod2man

# Makepkg does not allow running as root
# Create a new user `builder`
# `builder` needs to have a home directory because some PKGBUILDs will try to
# write to it (e.g. for cache)
useradd builder -m
# When installing dependencies, makepkg will use sudo
# Give user `builder` passwordless sudo access
echo "builder ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# Give all users (particularly builder) full access to these files
chmod -R 777 .

BASEDIR="$(pwd)"

if [ ! -d "$INPUT_PKGDIR" ]; then
	echo "Building from AUR..."
	sudo -H -u builder git clone "https://aur.archlinux.org/$INPUT_PKGDIR"
fi

cd "${INPUT_PKGDIR:-.}"
sudo -H -u builder updpkgsums

# Assume that if .SRCINFO is missing or mismatch
# Recreating .SRCINFO
echo "Creating .SRCINFO"
sudo -H -u builder makepkg --printsrcinfo > .SRCINFO

# Extract AUR dependencies from .SRCINFO (depends or depends_x86_64) and install
mapfile -t NEEDED < \
	<(sed -n -e 's/^[[:space:]]*\(make\)\?depends\(_x86_64\)\? = \([[:alnum:][:punct:]]*\)[[:space:]]*$/\3/p' .SRCINFO)


if [ ${#NEEDED[@]} -eq 0 ]; then
  echo "No dependencies found."
else
  if [[ -n "$NEEDED" && "$NEEDED" =~ ^[[:alpha:]]+$ ]]; then
    mapfile -t PKGDEPS < <(pacman -T ${NEEDED[@]})

    if [[ $NEEDED == *"rust"* ]] || [[ $NEEDED == *"cargo"* ]]; then
      pacman -Syu --noconfirm rust
      rustc --version
    fi

	sudo -H -u builder yay -S ${PKGDEPS[@]} --noconfirm --needed
  fi
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
	# Caller arguments to makepkg may mean the pacakge is not built
	if [ -f "$PKGFILE" ]; then
		echo "::set-output name=pkgfile$i::$RELPKGFILE"
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
	# Run namcap checksappend_path: command not found
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
