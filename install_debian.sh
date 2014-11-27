#!/bin/sh
#
# install_debian.sh Installs Debian base system for N900
# Distributable under the terms of the GNU GPL version 3.

set -e
set -u

abort()
{
	echo ERROR: $1 >&2
	exit 1
}

clean_up()
{
	trap - 0 1 2 15
	
	for path in $MOUNTPOINT/dev/pts $MOUNTPOINT/dev $MOUNTPOINT/proc; do
		test `grep -q $path /proc/mounts` && umount $path
	done
	
	echo "Installation failed" >&2
	exit 1
}

DIR=`dirname $0`

# Source configuration files
. $DIR/kernel.conf
. $DIR/debian.conf

# Use "set -u" to ensure that all required variables are set
: $MOUNTPOINT
: $FSTYPE
: $UMASK
: $RELEASE
: $ARCH
: $MIRROR
: $HOSTNAME
: $CMDLINE
: $SWAPDEVICE
: $BOOTSEQUENCE
: $KEYMAP_URL
: $XKB_URL
: $XKB_PATCHES
: $XKBLAYOUT
: $ESSENTIAL
: $RECOMMENDED
: $NONFREE
: $INIT
: $USB_ADDRESS
: $USB_NETMASK
: $USB_GATEWAY
: $USERNAME
: $REALNAME
: $INSTALL_MOD_PATH

# Check user
test `id -u` -eq 0 || abort "Must be root"

# Check for presence of required utilities
UTILS="mount id cut chroot sed awk qemu-debootstrap wget fold"
for util in $UTILS; do
	command -pv $util > /dev/null || abort "$util not found"
done

# Use GIT_REPO_NAME as the relative path of the kernel source unless KERNELSOURCE was explicitly specified in config file
: ${KERNELSOURCE:=$GIT_REPO_NAME}

# Set the path to the zImage
: ${ZIMAGE:=$KERNELSOURCE/arch/arm/boot/zImage}

# Get kernel release name
KERNELRELEASE=`cat $KERNELSOURCE/include/config/kernel.release`
: ${KERNELRELEASE:?}

# Check for presence of zImage
test -f $ZIMAGE || abort "zImage not found"

# Set path to kernel modules
if [ `echo $INSTALL_MOD_PATH | cut -c 1` = / ]; then
	KERNELMODULES=$INSTALL_MOD_PATH/lib/modules
else
	KERNELMODULES=$KERNELSOURCE/$INSTALL_MOD_PATH/lib/modules
fi

# Check for presence of kernel modules
test -d $KERNELMODULES/$KERNELRELEASE || abort "Kernel modules not found"

# Check that filesystem has been mounted and is of expected type
test x$FSTYPE = x`awk '{ if ($2 == "'$MOUNTPOINT'") print $3 }' < /proc/mounts` || abort "Unexpected filesystem or filesystem not mounted"

# Check that mounted filesystem contains nothing but lost+found
test xlost+found = x`ls $MOUNTPOINT` || abort "Filesystem already contains data or is not formatted correctly"

# Set up the root device name
SLICE=`awk '{ if ($2 == "'$MOUNTPOINT'") print substr($1, length($1), 1) }' < /proc/mounts`
ROOTDEVICE=/dev/mmcblk0p$SLICE

# Print disclaimer
echo "DISCLAIMER: Care has been taken to ensure that these scripts are safe to run however should they happen break something or mess anything up, the author takes no responsibility whatsoever.  Use at your own risk!" | fold -s
printf "Continue? Y/[N]: "
read disclaimer
: ${disclaimer:=}
test "x$disclaimer" = xY || test "x$disclaimer" = xy || exit 1

# Print non-free package warning
echo "WARNING: This script enables non-free repositories in order to install the wireless network adapter." | fold -s
printf "Continue? Y/[N]: "
read warning
: ${warning:=}
test "x$warning" = xY || test "x$warning" = xy || exit 1

# Set umask
umask $UMASK

# Set signal traps
trap clean_up 0 1 2 15

# Bootstrap Debian system
qemu-debootstrap --arch=$ARCH --variant=minbase --include=$ESSENTIAL,$RECOMMENDED $RELEASE $MOUNTPOINT $MIRROR

# Configure APT data sources
echo "deb $MIRROR $RELEASE main contrib non-free" > $MOUNTPOINT/etc/apt/sources.list

if [ $RELEASE != "unstable" ]; then
	printf "deb $MIRROR $RELEASE-updates main contrib non-free\ndeb http://security.debian.org/ $RELEASE/updates main contrib non-free\n" >> $MOUNTPOINT/etc/apt/sources.list
fi

# Set up hostname
echo $HOSTNAME > $MOUNTPOINT/etc/hostname
sed -i 's/127\.0\.0\.1.*$/& '$HOSTNAME'/' $MOUNTPOINT/etc/hosts

# Create filesystem table
cat << EOF > $MOUNTPOINT/etc/fstab
# /etc/fstab: static file system information.
#
# <file system> <mount point>   <type>  <options>       <dump>  <pass>
$ROOTDEVICE	/	$FSTYPE	errors=remount-ro,noatime	0	0
proc	/proc	proc	nodev,noexec,nosuid	0	0
none	/tmp	tmpfs	noatime	0	0
$SWAPDEVICE	none	swap	sw	0	0
EOF

# Change power button behaviour
if [ x${POWER_BUTTON_ACTION:-} != x ]; then
	sed -i 's/\(action=\).*$/\1'$POWER_BUTTON_ACTION'/' $MOUNTPOINT/etc/acpi/events/powerbtn-acpi-support
fi

# Create network interface configuration
# TODO: Fix USB networking
cat << EOF > $MOUNTPOINT/etc/network/interfaces
# interfaces(5) file used by ifup(8) and ifdown(8)
# Include files from /etc/network/interfaces.d:
source-directory /etc/network/interfaces.d

auto lo
iface lo inet loopback

auto wlan0
iface wlan0 inet dhcp
${WLAN0_HWADDRESS:+	hwaddress $WLAN0_HWADDRESS}

auto usb0
iface usb0 inet static
	address $USB_ADDRESS
	netmask $USB_NETMASK
	gateway $USB_GATEWAY
	pre-up modprobe g_nokia
	post-down rmmod g_nokia
EOF

# Create X11 configuration file
# Touchscreen can be recalibrated with xinput-calibrator(5)
cat << EOF > $MOUNTPOINT/etc/X11/xorg.conf
Section "InputClass"
	Identifier "calibration"
	MatchProduct "TSC2005 touchscreen"
	Option "Calibration" "216 3910 3747 245"
	Option "EmulateThirdButton" "$EMULATETHIRDBUTTON"
	Option "EmulateThirdButtonTimeout" "$EMULATETHIRDBUTTONTIMEOUT"
	Option "EmulateThirdButtonMoveThreshold" "$EMULATETHIRDBUTTONMOVETHRESHOLD"
	Option "SwapAxes" "0"
EndSection
EOF

# This temporary workaround syncs the OS clock with the RTC on system boot
sed -i '/exit 0/d' $MOUNTPOINT/etc/rc.local
printf "hwclock -u -s\nexit 0\n" >> $MOUNTPOINT/etc/rc.local

# This temporary workaround prevents udev from changing the wlan0 device name
echo "# Unknown net device (/devices/68000000.ocp/480ba000.spi/spi_master/spi4/spi4.0/net/wlan0) (wl1251)" > $MOUNTPOINT/etc/udev/rules.d/70-persistent-net.rules
echo 'SUBSYSTEM=="net", ACTION=="add", DRIVERS=="?*", ATTR{address}=="?*", ATTR{dev_id}=="0x0", ATTR{type}=="1", KERNEL=="wlan*", NAME="wlan0"' >> $MOUNTPOINT/etc/udev/rules.d/70-persistent-net.rules

# Copy kernel zImage to Debian
cp $ZIMAGE $MOUNTPOINT/boot/zImage-$KERNELRELEASE

# Copy kernel modules to Debian
cp -R $KERNELMODULES $MOUNTPOINT/lib

# Remove stale symlinks
rm $MOUNTPOINT/lib/modules/$KERNELRELEASE/build $MOUNTPOINT/lib/modules/$KERNELRELEASE/source

# Set up initramfs modules
printf "omaplfb\nsd_mod\nomap_hsmmc\nmmc_block\nomap_wdt\ntwl4030_wdt\n" >> $MOUNTPOINT/etc/initramfs-tools/modules

# Create update-initramfs hook to update u-boot images
mkdir -p $MOUNTPOINT/etc/initramfs/post-update.d
cat << EOF > $MOUNTPOINT/etc/initramfs/post-update.d/update-u-boot
#!/bin/sh
#
# update-u-boot update-initramfs hook to update u-boot images
# Distributable under the terms of the GNU GPL version 3.

KERNELRELEASE=\$1
INITRAMFS=\$2

# Create uInitrd under /boot
mkimage -A arm -O linux -T ramdisk -C none -a 0 -e 0 -n initramfs -d \$INITRAMFS /boot/uInitrd-\$KERNELRELEASE

EOF
chmod +x $MOUNTPOINT/etc/initramfs/post-update.d/update-u-boot

# Create u-boot commands
cat << EOF > $MOUNTPOINT/boot/u-boot.cmd
setenv mmcnum 0
setenv mmcpart $SLICE
setenv mmctype $FSTYPE
setenv bootargs root=$ROOTDEVICE $CMDLINE
setenv setup_omap_atag
setenv mmckernfile /boot/uImage-$KERNELRELEASE
setenv mmcinitrdfile /boot/uInitrd-$KERNELRELEASE
setenv mmcscriptfile
run trymmckerninitrdboot
EOF

# Create script to be run inside Debian chroot
cat << EOF > $MOUNTPOINT/var/tmp/finalstage.sh
#!/bin/sh
#
# finalstage.sh Script to be run inside Debian chroot
# Distributable under the terms of the GNU GPL version 3.

set -e
set -u

# Generate modules.dep and map files
depmod $KERNELRELEASE

# Generate an initramfs image
update-initramfs -c -k $KERNELRELEASE

# Create uImage under /boot
mkimage -A arm -O linux -T kernel -C none -a 80008000 -e 80008000 -n $KERNELRELEASE -d /boot/zImage-$KERNELRELEASE /boot/uImage-$KERNELRELEASE

# Create boot.scr
mkimage -A arm -O linux -T script -C none -a 0 -e 0 -n debian900 -d /boot/u-boot.cmd /boot.scr

# Install non-free packages
apt-get update
apt-get -y --no-install-recommends install $NONFREE $INIT

# Console keyboard set up
wget --no-check-certificate -O /var/tmp/rx51_us.map $KEYMAP_URL
sed -i -e '/^XKBMODEL/ s/".*"/"nokiarx51"/' \
	-e '/^XKBLAYOUT/ s/".*"/"$XKBLAYOUT"/' \
	-e '/^XKBVARIANT/ s/".*"/"${XKBVARIANT:-}"/' \
	-e '/^XKBOPTIONS/ s/".*"/"${XKBOPTIONS:-}"/' /etc/default/keyboard
echo 'KMAP="/etc/console/boottime.kmap.gz"' >> /etc/default/keyboard

# Run install-keymap on boot as it cannot be run under a qemu chroot
cat > /etc/init.d/runonce << EOF2
#!/bin/sh
### BEGIN INIT INFO
# Provides:          runonce
# Required-Start:    \\\$remote_fs
# Required-Stop:
# X-Start-Before:    console-setup
# Default-Start:     S
# Default-Stop:
# X-Interactive:     true
### END INIT INFO
install-keymap /var/tmp/rx51_us.map
rm /etc/init.d/runonce
update-rc.d runonce remove
EOF2

chmod +x /etc/init.d/runonce
update-rc.d runonce defaults

# X11 keyboard set up
for patch in $XKB_PATCHES; do
	wget --no-check-certificate -O /var/tmp/\$patch $XKB_URL\$patch
	patch /usr/share/X11/xkb/symbols/nokia_vndr/rx-51 < /var/tmp/\$patch
done

# Reconfigure locales and time zone
dpkg-reconfigure locales
dpkg-reconfigure tzdata

# Set root password
echo "Setting root user password..."
while ! passwd; do
	:
done

# Set unprivileged user password
echo "Setting $USERNAME user password..."
useradd -c "$REALNAME" -m -s /bin/bash $USERNAME
while ! passwd $USERNAME; do
	:
done
EOF

# Make finalstage.sh executable
chmod +x $MOUNTPOINT/var/tmp/finalstage.sh

# Run finalstage.sh under chroot
mount -t proc proc $MOUNTPOINT/proc
mount -o bind /dev $MOUNTPOINT/dev
mount -o bind /dev/pts $MOUNTPOINT/dev/pts
ln -s /proc/mounts $MOUNTPOINT/etc/mtab
LC_ALL=C chroot $MOUNTPOINT /var/tmp/finalstage.sh

umount $MOUNTPOINT/dev/pts $MOUNTPOINT/dev $MOUNTPOINT/proc

# Create U-Boot configuration script
cat << EOF > configure_u-boot.sh
#!/bin/sh
#
# configure_u-boot.sh Configures U-Boot under Maemo

set -e
set -u

abort()
{
	echo ERROR: \$1 >&2
	exit 1
}

# Hardware check
test x\`awk '/product/ { print \$2 }' < /proc/component_version\` = xRX-51 || abort "Must be executed on N900 under Maemo"

# Check that pali's U-Boot is installed
UBOOTVERSION=\`dpkg -l u-boot-tools | grep ^ii | awk '{ print \$3 }' | cut -c 1-4\`
test \$UBOOTVERSION -ge 2013 || abort "Compatible U-Boot version not found"

# Check user
test \`id -u\` -eq 0 || abort "Must be root"

# Ensure that bootmenu.d directory exists
mkdir -p /etc/bootmenu.d

# Create U-Boot configuration file
cat > /etc/bootmenu.d/$BOOTSEQUENCE-Debian_GNU_Linux-$RELEASE-$ARCH-$KERNELRELEASE.item << EOF2
ITEM_NAME="Debian GNU/Linux $RELEASE $ARCH $KERNELRELEASE"
ITEM_DEVICE="\\\${EXT_CARD}p${ROOTDEVICE##*p}"
ITEM_FSTYPE="$FSTYPE"
ITEM_KERNEL="/boot/uImage-$KERNELRELEASE"
ITEM_INITRD="/boot/uInitrd-$KERNELRELEASE"
ITEM_CMDLINE="root=$ROOTDEVICE $CMDLINE"
EOF2

# Update U-Boot Bootmenu
u-boot-update-bootmenu || abort "U-Boot Bootmenu update failed"
EOF

# Unset trap on exit
trap - 0

printf "\nStage 1 of installation complete.\nRun configure_u-boot.sh on N900 to complete installation.\n"
