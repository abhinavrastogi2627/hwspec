#!/usr/bin/env bash
# Usage: scripts/vm-run.sh IMAGE BINARY [VERSION]
#
# Boots IMAGE (a pinned cloud image, below) under KVM, runs the amd64 hwspec
# BINARY inside it with scripts/vm-check.sh, and checks the results: the
# version (when VERSION is given), a user's capture (schema, VM detected,
# the image's init, every PCI device named) and a root --full capture.
#
# Needs: /dev/kvm (read-write), qemu-system-x86_64, qemu-img, UEFI firmware
# ($OVMF_CODE and $OVMF_VARS, default: Ubuntu's ovmf package), genisoimage,
# curl, jq, sha256sum/sha512sum, timeout. Downloads are cached in $VM_CACHE
# (default ~/.cache/hwspec-vm); logs and captures go to $VM_OUT (default
# vm-out/IMAGE). Exits non-zero on any failed check.
set -euo pipefail

image=${1:?image}; bin=${2:?binary}; want_version=${3:-}

# Pinned by checksum: a refreshed image is a deliberate change to this table.
# mode: cloud-init runs the check directly, or (sysvinit) switches init first.
case $image in
ubuntu-24.04)
	url=https://cloud-images.ubuntu.com/releases/24.04/release-20260926/ubuntu-24.04-server-cloudimg-amd64.img
	sum=sha256:6a81c37564db9b1ee84e141922625e1d7c5b389b99bb3c572e0243607d5bb4d2 init=systemd mode=direct ;;
ubuntu-26.04)
	url=https://cloud-images.ubuntu.com/releases/26.04/release-20260927/ubuntu-26.04-server-cloudimg-amd64.img
	sum=sha256:8800651811af9a85465ad1d552add729947bb16488dddb4a9b5305a3d97332b2 init=systemd mode=direct ;;
debian-13 | debian-13-sysvinit)
	url=https://cloud.debian.org/images/cloud/trixie/20261001-2618/debian-13-genericcloud-amd64-20261001-2618.qcow2
	sum=sha512:f46f0671a6e5bdec5291ab8972bae2f10e5408c2f64a74078f11efc2f06a436a9d0313ed50e0472542eeabf780e9f7c792ac0a314c6c20507fcd9fd81b468c3d
	init=systemd mode=direct
	if [ "$image" = debian-13-sysvinit ]; then init=init mode=sysvinit; fi ;;
fedora-44)
	url=https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-44-1.7.x86_64.qcow2
	sum=sha256:28680fe5b371a5a82ebf43a31926e086a168e59949d03969c5093e7071f90b7f init=systemd mode=direct ;;
arch)
	url=https://geo.mirror.pkgbuild.com/images/v20261001.604814/Arch-Linux-x86_64-cloudimg-20261001.604814.qcow2
	sum=sha256:360f0fa49db6813bdc8e35bed230a2dc2ae3567b7b5ab74719c0a706e4e34e87 init=systemd mode=direct ;;
alpine-3.24) # OpenRC under busybox init, so PID 1 is "init"
	url=https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/cloud/alpine-3.24.2-x86_64-cloudinit-r0.qcow2
	sum=sha512:c9504d23613f304e0cfb6f5fec872e29e5a5a62e2bc64796daf19c14fdddaa87dc252912fd8bdd17f7b8ebf0cd03305e4075993d54de175e6028d6b50414c67f
	init=init mode=direct ;;
*)
	echo "unknown image '$image'" >&2; exit 2 ;;
esac

fail() { echo "FAIL ($image): $*" >&2; exit 1; }
[ -r /dev/kvm ] && [ -w /dev/kvm ] || fail "/dev/kvm is missing or not read-write for $(id -un)"
[ -f "$bin" ] || fail "no binary at $bin"
here=$(cd "$(dirname "$0")" && pwd)
cache=${VM_CACHE:-$HOME/.cache/hwspec-vm}
out=${VM_OUT:-vm-out/$image}
mkdir -p "$cache" "$out"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# 1. The image, verified before every use (the cache may be restored from CI).
base=$cache/${url##*/}
verified() { echo "${sum#*:}  $base" | "${sum%%:*}sum" -c --quiet - >/dev/null 2>&1; }
if ! verified; then
	echo "Downloading $url"
	curl -fL --retry 3 --no-progress-meter -o "$base.part" "$url"
	mv "$base.part" "$base"
	verified || fail "checksum mismatch for $url"
fi
qemu-img create -q -f qcow2 -F qcow2 -b "$base" "$work/disk.qcow2" 12G

# 2. The NoCloud seed, which also carries the payload: binary and check script.
seed=$work/seed
mkdir "$seed"
install -m 755 "$bin" "$seed/hwspec"
install -m 755 "$here/vm-check.sh" "$seed/vm-check.sh"
printf 'instance-id: hwspec-%s\nlocal-hostname: hwspec-vm\n' "$image" >"$seed/meta-data"
mount_seed='mkdir -p /run/hwspec-seed && mount -o ro /dev/sr0 /run/hwspec-seed'
case $mode in
direct)
	cat >"$seed/user-data" <<-EOF
		#cloud-config
		runcmd:
		  - [sh, -c, '$mount_seed; sh /run/hwspec-seed/vm-check.sh; poweroff']
	EOF
	;;
sysvinit)
	# Boot 1 (systemd): swap in sysvinit and an init script, then reboot.
	# Boot 2 (sysvinit): the init script runs the check and powers off.
	cat >"$seed/hwspec-check.init" <<-'EOF'
		#!/bin/sh
		### BEGIN INIT INFO
		# Provides:          hwspec-check
		# Required-Start:    $all
		# Required-Stop:
		# Default-Start:     2 3 4 5
		# Default-Stop:
		# Short-Description: hwspec CI check (scripts/vm-run.sh)
		### END INIT INFO
		[ "$1" = start ] || exit 0
		sh /usr/local/lib/hwspec-check/vm-check.sh
		poweroff &
	EOF
	cat >"$seed/switch.sh" <<-'EOF'
		#!/bin/sh
		set -e
		lib=/usr/local/lib/hwspec-check
		mkdir -p "$lib"
		cp /run/hwspec-seed/hwspec /run/hwspec-seed/vm-check.sh "$lib/"
		install -m 755 /run/hwspec-seed/hwspec-check.init /etc/init.d/hwspec-check
		apt-get update -q
		# systemd-sysv must go explicitly, and it's Protected (apt calls it
		# essential): sysvinit-core takes over as the init provider.
		DEBIAN_FRONTEND=noninteractive apt-get install -y -q --allow-remove-essential \
			sysvinit-core sysv-rc orphan-sysvinit-scripts systemd-sysv-
		update-rc.d hwspec-check defaults
	EOF
	# The switch's exit code goes to the payload port, so a failed switch
	# fails after boot 1 instead of timing out in a second systemd boot.
	cat >"$seed/user-data" <<-EOF
		#cloud-config
		runcmd:
		  - [sh, -c, '$mount_seed && sh /run/hwspec-seed/switch.sh; echo "==> switch rc=\$?" >/dev/ttyS1; reboot']
	EOF
	;;
esac
genisoimage -quiet -output "$work/seed.iso" -volid cidata -joliet -rock "$seed"

# 3. Boot under UEFI (Debian 13's image resets right after GRUB under
# SeaBIOS). -no-reboot makes a reboot end QEMU too, so each boot is one run.
# No VGA: QEMU's (1234:1111) isn't in pci.ids, and every device is named.
cp "${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}" "$work/vars.fd" # boot entries persist across boots
boot() { # LOG
	timeout 600 qemu-system-x86_64 -enable-kvm -machine q35 -cpu host -smp 2 -m 2048 \
		-drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}" \
		-drive "if=pflash,format=raw,file=$work/vars.fd" \
		-display none -vga none -no-reboot \
		-serial "file:$1" -serial "file:$work/payload.log" \
		-drive "if=virtio,format=qcow2,file=$work/disk.qcow2" \
		-cdrom "$work/seed.iso" \
		-nic user,model=virtio-net-pci ||
		fail "QEMU failed or timed out after 10 minutes; see $1"
}
start=$SECONDS
if [ "$mode" = sysvinit ]; then
	echo "Boot 1/2 ($image): switching to sysvinit"
	boot "$out/console-1.log"
	tr -d '\r' <"$work/payload.log" >"$out/switch.log"
	grep -qx '==> switch rc=0' "$out/switch.log" || {
		tail -n 40 "$out/console-1.log" >&2
		fail "switching to sysvinit failed ($(cat "$out/switch.log")); console log above"
	}
	echo "Boot 2/2 ($image): running the check under sysvinit"
	boot "$out/console.log"
else
	echo "Booting $image"
	boot "$out/console.log"
fi
echo "VM ran for $((SECONDS - start)) s"

# 4. Split the payload log into one file per step, then check.
tr -d '\r' <"$work/payload.log" >"$out/payload.log"
awk -v d="$out" '/^==> /{ f = d "/" $2; printf "" > f; next } f { print > f }' "$out/payload.log"
grep -qx '==> end' "$out/payload.log" || {
	tail -n 40 "$out/console.log" >&2
	fail "the check didn't finish (console log above)"
}
rc() { sed -n "s/^==> $1 rc=//p" "$out/payload.log"; }
for s in version capture full; do
	[ "$(rc $s)" = 0 ] || { cat "$out/$s.stderr" >&2; fail "'$s' exited $(rc $s)"; }
done

version=$(cat "$out/version")
if [ -n "$want_version" ]; then
	[ "$version" = "hwspec $want_version" ] || fail "version '$version' isn't $want_version"
fi
jq --arg init "$init" '{
	schema: (.schema_version == 1),
	vm: (.os.virtualization == "vm"),
	uefi: (.os.boot_mode == "uefi"),
	init: (.os.init == $init),
	memory: (.memory.total_bytes > 0),
	pci_named: ((.pci | length) > 0 and all(.pci[]; (.identity.vendor // "") != "")),
	unprivileged: (.privileged == false),
	os: .os.pretty_name, os_init: .os.init, kernel: .os.kernel, warnings: .warnings
}' "$out/capture" | tee "$out/checks.json"
jq -e '[.schema, .vm, .uefi, .init, .memory, .pci_named, .unprivileged] | all' "$out/checks.json" >/dev/null ||
	fail "capture checks failed (above)"
jq -e '.privileged == true and .schema_version == 1' "$out/full" >/dev/null ||
	fail "the root --full capture isn't privileged"
mv "$out/capture" "$out/capture.json"
mv "$out/full" "$out/full.json"
echo "PASS ($image): $version, init $(jq -r .os_init "$out/checks.json"), $(jq -r .os "$out/checks.json")"
