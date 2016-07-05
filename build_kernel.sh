#!/bin/sh
#
# build_kernel.sh Checks out the kernel source from Git and builds it
# Distributable under the terms of the GNU GPL version 3.

set -e
set -u

abort()
{
	echo ERROR: $1 >&2
	exit 1
}

DIR=`dirname $0`

# Source configuration files
. $DIR/kernel.conf
test -r $DIR/kernel.conf.local && . $DIR/kernel.conf.local

# Check for presense of utilities
UTILS="id git ${CROSS_COMPILE}gcc nice make grep sed dpkg dpkg-genchanges dpkg-gencontrol dpkg-source"
for util in $UTILS; do
	command -pv $util > /dev/null || abort "$util not found"
done

test `id -u` -ne 0 || abort "Must not be root"

# Checkout kernel
test -d $GIT_REPO_NAME && echo "$GIT_REPO_NAME directory already exists.  Skipping cloning of Git repository." || git clone -b $GIT_BRANCH ${GIT_CLONE_DEPTH:+--depth $GIT_CLONE_DEPTH} $GIT_KERNEL_URI

cd $GIT_REPO_NAME

# Export environment variables needed for build
export ARCH CROSS_COMPILE

# Build default config for N900
nice -n $NICENESS make -j $JOBS rx51_defconfig

# Disable CONFIG_SYSFS_DEPRECATED which is only needed for Maemo
sed -i -e 's/\(CONFIG_SYSFS_DEPRECATED\)=y/# \1 is not set/' \
	-e '/CONFIG_SYSFS_DEPRECATED_V2/d' .config

# Disable PHYLIB if building Linux 3.16-rc1 due to dependency cycle bug that breaks depmod
test $GIT_BRANCH = "v3.16-rc1-n900" && sed -i 's/\(CONFIG_PHYLIB\)=m/# \1 is not set/' .config

if [ x$ENABLE_LXC = xY ] || [ x$ENABLE_LXC = xy ]; then
	# Enable LXC support
	sed -i -e 's/# \(CONFIG_CGROUP_DEVICE\) is not set/\1=y/' \
		-e 's/# \(CONFIG_CGROUP_CPUACCT\) is not set/\1=y/' \
		-e 's/# \(CONFIG_MEMCG\) is not set/\1=y\n# CONFIG_MEMCG_SWAP is not set\n# CONFIG_MEMCG_KMEM is not set/' \
		-e 's/# \(CONFIG_NAMESPACES\) is not set/\1=y\nCONFIG_UTS_NS=y\nCONFIG_IPC_NS=y\nCONFIG_USER_NS=y\nCONFIG_PID_NS=y\nCONFIG_NET_NS=y/' \
		-e 's/# \(CONFIG_MACVLAN\) is not set/\1=y\n# CONFIG_MACVTAP is not set/' \
		-e 's/# \(CONFIG_VETH\) is not set/\1=y/' \
		-e 's/# \(CONFIG_DEVPTS_MULTIPLE_INSTANCES\) is not set/\1=y/' .config
fi

if [ x$ENABLE_OVERLAYFS = xY ] || [ x$ENABLE_OVERLAYFS = xy ]; then
	# Enable OverlayFS support
	sed -i 's/# \(CONFIG_OVERLAY_FS\) is not set/\1=y/' .config
fi

if [ x$ENABLE_RFKILL = xY ] || [ x$ENABLE_RFKILL = xy ]; then
	# Enable rfkill support
	sed -i 's/# \(CONFIG_RFKILL\) is not set/\1=y\n# CONFIG_RFKILL_INPUT is not set\n# CONFIG_RFKILL_GPIO is not set\n# CONFIG_USB_HSO is not set\n# CONFIG_RADIO_WL128X is not set\n# CONFIG_R8723AU is not set/' .config
fi

# Modify postinst script to append the device tree and then build the U-Boot kernel image
cat << EOF > scripts/package/insert_postinst_cmds.sh
#!/bin/sh
sed -i '/exit 0/i \\
cat /usr/lib/linux-image-'\$1'/omap3-n900.dtb >> /boot/vmlinuz-'\$1' \\
mkimage -A arm -O linux -T kernel -C none -a 80008000 -e 80008000 -n '\$1' -d /boot/vmlinuz-'\$1' /boot/uImage-'\$1 debian/tmp/DEBIAN/postinst
EOF
chmod +x scripts/package/insert_postinst_cmds.sh
sed -i '/# Try to determine maintainer and email values/i scripts/package/insert_postinst_cmds.sh $version' scripts/package/builddeb

# Build kernel and deb packages
nice -n $NICENESS make -j $JOBS deb-pkg
