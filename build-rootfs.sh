#!/usr/bin/env bash

set -e

usage()
{
	echo "Usage: $0 BuildArch [--jobs <N>] [--rootfsdir <directory>]"
	echo "BuildArch can be: x86, x86_64, x86h, x86_gcc2h"
	echo "--rootfsdir dir - optional, defaults to current dir, where to"
	echo "                  put cross-compiler and Haiku sysroot."
	echo "--jobs N        - optional, restrict to N jobs."
	echo "--branch name   - optional, branch to clone Haiku source."
	echo "--repo link     - optional, URL to Haiku source repo."
	exit 1
}

__InitialDir=$PWD
__RootfsDir="$__InitialDir"

case $1 in
	x86|x86_64)
		__BuildArch=$1
		;;
	x86h)
		__BuildArch=x86
		__BuildSecondaryArch=x86_gcc2
		;;
	x86_gcc2h)
		__BuildArch=x86_gcc2
		__BuildSecondaryArch=x86
		;;
	*)
		usage
		;;
esac

shift

while :; do
	if [ $# -le 0 ]; then
		break
	fi

	case $1 in
		--rootfsdir|-rootfsdir)
			shift
			__RootfsDir=$1
			;;
		--jobs|-jobs)
			shift
			MAXJOBS=$1
			;;
		--branch|-branch)
			shift
			__Branch=$1
			;;
		--repo|-repo)
			shift
			__Repo=$1
			;;
		*)
			usage
			;;
	esac

	shift
done


if [ -z "$__RootfsDir" ] && [ ! -z "$ROOTFS_DIR" ]; then
	__RootfsDir=$ROOTFS_DIR
fi

if [ -z "$__Branch" ] ; then
	__Branch="master"
fi

if [ -z "$__Repo" ] ; then
	__Repo="https://github.com/haiku/haiku"
fi

echo "Using $__RootfsDir..."
echo "Using Haiku source from $__Repo on branch $__Branch"

mkdir -p $__RootfsDir
__RootfsDir="$( cd "$__RootfsDir" && pwd )"

JOBS=${MAXJOBS:="$(getconf _NPROCESSORS_ONLN)"}

if [ -z "$__BuildSecondaryArch" ]; then
	echo "Building Haiku sysroot for $__BuildArch"
else
	echo "Building Haiku sysroot for $__BuildArch/$__BuildSecondaryArch hybrid"
fi
mkdir -p "$__RootfsDir/tmp"
pushd "$__RootfsDir/tmp"
if [ ! -e "$__RootfsDir/tmp/haiku/.git" ]; then
	git clone $__Repo -b $__Branch
	pushd haiku && git remote add review https://review.haiku-os.org/haiku && git fetch --tags review && popd
	#git clone --depth=1 https://review.haiku-os.org/haiku
else
	echo "WARN: skipping clone of haiku repo, already exists"
fi

if [ ! -e "$__RootfsDir/tmp/buildtools/.git" ]; then
	git clone --depth=1 https://github.com/haiku/buildtools
else
	echo "WARN: skipping clone of buildtools repo, already exists"
fi

# Fetch some patches that haven't been merged yet
cd "$__RootfsDir/tmp/haiku"
git reset --hard origin/master
## add development build profile (slimmer than nightly)
git am "$__InitialDir/0002-Add-extra-build-profile-development.patch"
## add the patch for providing an explicit sysroot
git am "$__InitialDir/0003-cross_tools-allow-specifying-a-custom-sysroot-path.patch"

# Build jam
echo 'Building jam buildtool'
cd "$__RootfsDir/tmp/buildtools/jam"
make

# Configure cross tools
echo "Building cross tools with $JOBS parallel jobs"
mkdir -p "$__RootfsDir/generated"
cd "$__RootfsDir/generated"
if [ -z "$__BuildSecondaryArch" ]; then
	"$__RootfsDir/tmp/haiku/configure" -j"$JOBS" --sysroot "$__RootfsDir" --cross-tools-source "$__RootfsDir/tmp/buildtools" --build-cross-tools $__BuildArch
else
	"$__RootfsDir/tmp/haiku/configure" -j"$JOBS" --sysroot "$__RootfsDir" --cross-tools-source "$__RootfsDir/tmp/buildtools" --build-cross-tools $__BuildArch --build-cross-tools $__BuildSecondaryArch
fi

# Build haiku packages
echo 'Building Haiku packages and package tool'
echo 'HAIKU_BUILD_PROFILE = "development-raw" ;' > UserProfileConfig
"$__RootfsDir/tmp/buildtools/jam/jam0" -j"$JOBS" -q '<build>package' '<repository>Haiku'

# Find the package command
__PackageCommand=`echo $__RootfsDir/generated/objects/*/*/release/tools/package/package`

# Setup the sysroot
echo 'Extracting packages into sysroot'
mkdir -p "$__RootfsDir/boot/system"
for file in "$__RootfsDir/generated/objects/haiku/$__BuildArch/packaging/repositories/Haiku/packages/"*.hpkg; do
	echo "Extracting $file..."
	"$__PackageCommand" extract -C "$__RootfsDir/boot/system" "$file"
done
for file in "$__RootfsDir/generated/download/"*.hpkg; do
	echo "Extracting $file..."
	"$__PackageCommand" extract -C "$__RootfsDir/boot/system" "$file"
done

# Create a script for running `package extract`
cat >"$__RootfsDir/package_extract.sh" <<EOF
#!/usr/bin/env bash

"$__PackageCommand" extract -C "$__RootfsDir/boot/system" "\$1"

echo "Extracted \$1 into the Haiku sysroot"
EOF
chmod +x "$__RootfsDir/package_extract.sh"

# Clean up
rm -rf "$__RootfsDir/tmp/" "$__RootfsDir/generated/objects/haiku/" "$__RootfsDir/generated/objects/common"
rm -rf "$__RootfsDir/generated/attributes/" "$__RootfsDir/generated/download/" "$__RootfsDir/generated/build_packages/"

# And done!
popd

if [ -z "$__BuildSecondaryArch" ]; then
	echo "Completed build of Haiku cross-compiler for $__BuildArch"
else
	echo "Completed build of Haiku cross-compiler for $__BuildArch/$__BuildSecondaryArch hybrid"
fi

echo ""
echo "Your cross-compiler is available in $__RootfsDir/generated/cross-tools-{ARCH}/bin/,"
echo "and the sysroot extracted into $__RootfsDir/boot/system."
echo ""
echo "You can also use $__RootfsDir/package_extract.sh to extract packages into the sysroot."
if [ -z "$__BuildSecondaryArch" ]; then
	echo "Download packages from https://eu.hpkg.haiku-os.org/haikuports/master/$__BuildArch/current/packages."
else
	echo "Download primary arch packages from https://eu.hpkg.haiku-os.org/haikuports/master/$__BuildArch/current/packages,"
	echo "and secondary arch packages from https://eu.hpkg.haiku-os.org/haikuports/master/$__BuildSecondaryArch/current/packages."
fi
echo ""
