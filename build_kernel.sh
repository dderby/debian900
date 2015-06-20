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
UTILS="id git ${CROSS_COMPILE}gcc nice make grep sed"
for util in $UTILS; do
	command -pv $util > /dev/null || abort "$util not found"
done

test `id -u` -ne 0 || abort "Must not be root"

# Checkout kernel
test -d $GIT_REPO_NAME && echo "$GIT_REPO_NAME directory already exists.  Skipping cloning of Git repository." || git clone $GIT_KERNEL_URI
cd $GIT_REPO_NAME
git checkout $GIT_BRANCH

# Export environment variables needed for build
export ARCH CROSS_COMPILE INSTALL_MOD_PATH

# Build default config for N900
nice $NICENESS make -j $JOBS rx51_defconfig

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

# Build kernel
nice $NICENESS make -j $JOBS

# Build kernel modules
nice $NICENESS make -j $JOBS modules_install

# Append DT to kernel image
cat arch/arm/boot/dts/omap3-n900.dtb >> arch/arm/boot/zImage
