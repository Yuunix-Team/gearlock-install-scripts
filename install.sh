#!/bin/bash

SUPPORTED_ARCH=(x86 x86_64 arm aarch64)
MIN_SUPPORTED_SDK=29
MIN_SDK=27
GSTATUS=None

GRLP_BIN_SRC=https://example.com/

LOG=/tmp/ginstall.log
STDOUT=/dev/stdout
STDERR=/dev/stderr
WARNOUT=/dev/stderr

CURRENT_DIR=$(pwd)
WORKDIR=$(mktemp)

CHROOTDIR=$WORKDIR/chroot
ANDROID=$WORKDIR/android

mkdir -p "$WORKDIR"
cd "$WORKDIR"

clean() {
	cd ..
	mount_teardown "$WORKDIR"
	rm -rf "$WORKDIR"
}
quit() {
	clean
	cd "$CURRENT_DIR"
	exit $?
}

err() { printf "ERROR: %s" "$@" >/dev/stderr; }
warn() { printf "WARNING: %s" "$@" >$WARNOUT; }
die() { err "$@" && quit 1; }

machine_info() {
	machine=$(uname -m)
	case $machine in
	i?86) GENKERNEL_ARCH="x86" ;;
	mips | mips64) GENKERNEL_ARCH="mips" ;;
	mipsel | mips64el) GENKERNEL_ARCH="mipsel" ;;
	arm*) GENKERNEL_ARCH="arm" ;;
	*) GENKERNEL_ARCH="$machine" ;;
	esac

	case "${SUPPORTED_ARCH[@]}" in
	*$GENKERNEL_ARCH*) ;;
	*) die "Architecture '$machine' is not supported" ;;
	esac

	# more in4 on os: ram, storage
	
	ram=$(free -h | grep Mem | awk '{print $2}')
}

# shellcheck disable=SC2317
android_info() {
	local os_abi os_sdk

	os_abi=$(pprop cpu.abi)
	case $os_abi in
	i?86) OS_ARCH="x86" ;;
	mips | mips64) OS_ARCH="mips" ;;
	mipsel | mips64el) OS_ARCH="mipsel" ;;
	arm*) OS_ARCH="arm" ;;
	*) OS_ARCH="$os_abi" ;;
	esac

	[ "$OS_ARCH" = "$GENKERNEL_ARCH" ] ||
		warn "The installed Android architecture does not match the system. Please check if the path provided is correct."

	os_sdk=$(bprop version.sdk)

	[ "$os_sdk" -gt "$MIN_SDK" ] ||
		die "Not supported Android version (supported: Android 8.1 and above, min SDK: $MIN_SDK, recommended: Android >= 10, SDK >= $MIN_SUPPORTED_SDK)"

	[ "$os_sdk" -gt "$MIN_SUPPORTED_SDK" ] ||
		warn "Better use Android 10 and above (SDK >= $MIN_SUPPORTED_SDK)"

	[ "$GSTATUS" = Installed ] &&
		warn "Gearlock is installed, performing update"

	case "$SYSTEM" in
	*_*) : ab ;;
	*) : "a only" ;;
	esac
	MODE=$_

	buildver=$(fprop "([a-z]*).version" | grep -v build)

	IFS="
"
	for ver in $buildver; do
		case $ver in
		ro.bliss.*) OS="Bliss OS $(prop "$ver")" && break ;;
		ro.phoenix.*) OS="Phoenix OS $(prop "$ver")" && break ;;
		ro.primeos.*) OS="Prime OS $(prop "$ver")" && break ;;
		ro.lineage.*) OS="Lineage OS $(prop "$ver")" ;;
		*) OS="AOSP $(bprop "version.release") $(bprop "flavor")" ;;
		esac
	done
	unset IFS

	printf "%s: %s" \
		"OS" "$OS" \
		"Boot mode" "$MODE" \
		"Architecture" "$OS_ARCH" \
		"SDK Level" "$os_sdk" \
		"GLRP status" "$GSTATUS"
}

# shellcheck disable=SC2317
loop_mount() {
	local disktmp
	disktmp="$(mktemp)"
	rm -f "$disktmp"
	mkdir -p "$disktmp" || true
	mount -o ro${2:+,$2} -t "${3:-auto}" "$1" "$disktmp" 2>/dev/null &&
		UNMOUNT_LIST="$disktmp $UNMOUNT_LIST" &&
		echo "$disktmp"
}

# shellcheck disable=SC2317
prop() { echo -n "${1#*=}"; }

# shellcheck disable=SC2317
fprop() { grep -E "ro.$1" "$BUILDPROP"; }

# shellcheck disable=SC2317
oprop() { prop "$(fprop "$1=")"; }

# shellcheck disable=SC2317
bprop() { oprop "build.$1"; }

# shellcheck disable=SC2317
pprop() { oprop "product.$1"; }

# shellcheck disable=SC2317
verify_system() {
	if [ ! -d "$1" ]; then
		local flag
		[ -f "$1" ] && flag=loop
		verify_system "$(loop_mount "$1" "$flag")"
		return $?
	fi

	BUILDPROP=$1/system/build.prop
	[ -f "$BUILDPROP" ] || return 1

	android_info
}

# shellcheck disable=SC2317
check_folder() {
	local SRC=$1
	pass_vf() {
		local file=$SRC/system$1$type
		[ -f "$file" ] &&
			verify_system "$file" &&
			SYSTEM=$file
	}

	if [ -f "$1/gearlock" ]; then
		cpio -t <"$1/gearlock" | grep usr/lib/gearlock &&
			GSTATUS=Installed ||
			GSTATUS=Legacy
	elif [ -d "$1/gearlock" ] || [ -f "$1/gearlock.img" ]; then
		GSTATUS=Installed
	fi

	for type in '' .img .sfs .efs; do
		(pass_vf "" || pass_vf "_a" || pass_vf "_b") && break
	done

	# check for available space
	freespace=$(df -m "$1" | tail -1 | awk '{print $4}')
	[ "$freespace" -ge 4096 ] ||
		die "Not enough space to install gearlock to '$1'"
}

check_dev() {
	devtype=$(lsblk -dpnro type "$1")
	case "$devtype" in
	disk) ;;
	Extended) ;;
	part) check_folder "$(loop_mount "$1")" || 
		die "Cannot process path '$1'" ;;
	esac
}

check() {
	# check if target folder path/block device/logical partition is a valid android distribution
	[ -e "$1" ] || die "Path '$1' does not exist or cannot be found"

	local TYPE
	[ -d "$1" ] && TYPE=folder || TYPE=dev

	"check_$TYPE" ||
		die "'$1' is not a valid Android installation"
}

build() {
	git clone https://github.com/Yuunix-Team/gearbuild
	cd gearbuild
	./setup.sh -a "$OS_ARCH" -i
	mv dist/gearlock.img "$WORKDIR"
	cd $WORKDIR
}

prepare() {
	# get the file from $GLRP_BIN_SRC
	# or build one
	echo
	build
}

chroot_add_mount() { mountpoint -q "$2" || mount "$@"; }

chroot_if_dir() { [ -d "$1" ] && shift && chroot_add_mount "$@" || true; }

mount_teardown() {
	umount $(mount | grep "on ${1%/}/" | awk '{print $3}' | tac | xargs)
}

chroot_setup() {
	mkdir -p "$1" &&
		chroot_add_mount proc "$1/proc" -t proc -o nosuid,noexec,nodev &&
		chroot_add_mount sys "$1/sys" -t sysfs -o nosuid,noexec,nodev,ro &&
		chroot_if_dir /sys/firmware/efi/efivars efivarfs "$1/sys/firmware/efi/efivars" -t efivarfs -o nosuid,noexec,nodev &&
		chroot_add_mount /dev "$1/dev" --rbind &&
		chroot_add_mount tmpfs "$1/data" -t tmpfs --bind &&
		chroot_add_mount "$ANDROID" "$1/android" --bind &&
		chroot_add_mount "$ANDROID"/system "$1/system" --bind &&
		chroot_add_mount "$ANDROID"/product "$1/product" --bind &&
		chroot_add_mount "$ANDROID"/vendor "$1/vendor" --bind &&
		chroot_if_dir "$ANDROID"/apex /android/apex "$1/apex" --rbind &&
		chroot_add_mount tmp "$1/tmp" -t tmpfs -o mode=1777,nodev,nosuid &&
		mount --make-rslave "$1"
}

setup_gearlock() {
	chroot_setup "$CHROOTDIR"
}

usage() {
	echo
	quit "$1"
}

main() {
	machine_info
	check "$TARGET"
	prepare
	setup_gearlock
}

while getopts "hwq" opt; do
	case "$opt" in
	h) usage 0 ;;
	w) SUPRESS_WARN=true ;;
	q) QUIET=true ;;
	*) usage 1 ;;
	esac
done
shift $((OPTIND - 1))

if [ "$QUIET" ]; then
	STDOUT=$LOG
	STDERR=$LOG
fi

if [ "$SUPRESS_WARN" ]; then
	WARNOUT=$LOG
fi

TARGET=$1

main >$STDOUT 2>$STDERR

quit 0
