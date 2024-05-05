#!/bin/bash
set -euo pipefail

FILE="$(basename "$0")"

echo $FILE

pacman -Syyu
pacman -Syu --noconfirm llvm-all yay wayland-protocols pacman-contrib pipewire wget

#force ld.lld as default linker
ln -fs /usr/bin/ld.lld /usr/bin/ld
ln -sf /usr/bin/ld.lld /usr/sbin/ld

#force replace gcc with clang
ln -fs /usr/bin/clang /usr/bin/gcc
ln -fs /usr/bin/clang++ /usr/bin/g++


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

BASEDIR="$PWD"
echo "$BASEDIR"

cd "${INPUT_PKGDIR:-.}"
sudo -H -u builder updpkgsums



# Assume that if .SRCINFO is missing or mismatch
# Recreating .SRCINFO
echo "Creating .SRCINFO"
sudo -H -u builder makepkg --printsrcinfo > .SRCINFO

# Extract AUR dependencies from .SRCINFO (depends or depends_x86_64) and install
# Extract AUR dependencies from .SRCINFO (depends or depends_x86_64) and install
mapfile -t NEEDED < \
	<(sed -n -e 's/^[[:space:]]*\(make\)\?depends\(_x86_64\)\? = \([[:alnum:][:punct:]]*\)[[:space:]]*$/\3/p' .SRCINFO)

mapfile -t PKGDEPS < \
	<(pacman -T ${NEEDED[@]})

if [[ $string == *"rust"* ]] || [[ $string == *"cargo"* ]]; then
  pacman -Syu rustup
  rustup toolchain install stable
fi

sudo -H -u builder yay -S ${PKGDEPS[@]} --noconfirm --needed


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
		NAMCAP_ARGS+=( "-e" "${INPUT_NAMCAPEXCLUDERULES}" )
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
