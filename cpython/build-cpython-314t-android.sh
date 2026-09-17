#!/bin/bash
set -eu -o pipefail

recipe_dir=$(dirname $(realpath $0))
PREFIX=${1:?}
mkdir -p "$PREFIX"
PREFIX=$(realpath "$PREFIX")

version=${2:?}
read version_major version_minor version_micro < <(
    echo $version | sed -E 's/^([0-9]+)\.([0-9]+)\.([0-9]+).*/\1 \2 \3/'
)
version_short=$version_major.$version_minor
version_no_pre=$version_major.$version_minor.$version_micro
version_int=$(($version_major * 100 + $version_minor))

abi=$(basename $PREFIX)
cd $recipe_dir
# This is Chaquopy's own target-build recipe with free-threading enabled, and it
# leans on two of Chaquopy's helper scripts. Point CHAQUOPY_ROOT at a checkout
# of https://github.com/chaquo/chaquopy (tested at f004380):
#   git clone https://github.com/chaquo/chaquopy "$FT_ROOT/chaquopy"
CHAQUOPY_ROOT=${CHAQUOPY_ROOT:-$FT_ROOT/chaquopy}
. "$CHAQUOPY_ROOT/target/abi-to-host.sh"
. "$CHAQUOPY_ROOT/target/android-env.sh"

# Download and unpack Python source code.
version_dir=$recipe_dir/build/$version
mkdir -p $version_dir
cd $version_dir
src_filename=Python-$version.tgz
wget -c https://www.python.org/ftp/python/$version_no_pre/$src_filename

build_dir=$version_dir/$abi
rm -rf $build_dir
tar -xf "$src_filename"
mv "Python-$version" "$build_dir"
cd "$build_dir"

# Apply patches.
patches=""
if [ $version_int -le 311 ]; then
    patches+=" sysroot_paths"
fi
if [ $version_int -eq 311 ]; then
    patches+=" python_for_build_deps"
fi
if [ $version_int -le 312 ]; then
    patches+=" soname"
fi
if [ $version_int -eq 312 ]; then
    patches+=" bldlibrary grp"
fi
for name in $patches; do
    patch_file="$recipe_dir/patches/$name.patch"
    echo "$patch_file"
    patch -p1 -i "$patch_file"
done

# Remove any existing installation in the prefix.
rm -rf $PREFIX/{include,lib}/python$version_short
rm -rf $PREFIX/lib/libpython$version_short*

if [ $version_int -le 312 ]; then
    # Download and unpack libraries needed to compile Python. For a given Python
    # version, we must maintain binary compatibility with existing wheels.
    libs="bzip2-1.0.8-3 libffi-3.4.4-3 openssl-3.0.18-0 sqlite-3.50.4-0 xz-5.4.6-1"

    url_prefix="https://github.com/beeware/cpython-android-source-deps/releases/download"
    for name_ver in $libs; do
        filename="$name_ver-$HOST.tar.gz"
        url="$url_prefix/$name_ver/$filename"
        echo "$url"
        curl -Lf --retry 5 --retry-all-errors -O "$url"
        tar -C $PREFIX -xf "$filename"
        rm "$filename"
    done

    # Add sysroot paths, otherwise Python 3.8's setup.py will think libz is unavailable.
    CFLAGS+=" -I$toolchain/sysroot/usr/include"
    LDFLAGS+=" -L$toolchain/sysroot/usr/lib/$HOST/$api_level"

    # The configure script omits -fPIC on Android, because it was unnecessary on older versions of
    # the NDK (https://bugs.python.org/issue26851). But it's definitely necessary on the current
    # version, otherwise we get linker errors like "Parser/myreadline.o: relocation R_386_GOTOFF
    # against preemptible symbol PyOS_InputHook cannot be used when making a shared object".
    export CCSHARED="-fPIC"

    # Override some tests.
    cd "$build_dir"
    cat > config.site <<-EOF
	# Things that can't be autodetected when cross-compiling.
	ac_cv_aligned_required=no  # Default of "yes" changes hash function to FNV, which breaks Numba.
	ac_cv_file__dev_ptmx=no
	ac_cv_file__dev_ptc=no
	EOF
    export CONFIG_SITE=$(pwd)/config.site

    configure_args="--host=$HOST --build=$(./config.guess) \
    --enable-shared --without-ensurepip --with-openssl=$PREFIX"

    # This prevents the "getaddrinfo bug" test, which can't be run when cross-compiling.
    configure_args+=" --enable-ipv6"

    # Some of the patches involve missing Makefile dependencies, which allowed extension
    # modules to be built before libpython3.x.so in parallel builds. In case this happens
    # again, make sure there's no libpython3.x.a, otherwise the modules may end up silently
    # linking with that instead.
    if [ $version_int -ge 310 ]; then
        configure_args+=" --without-static-libpython"
    fi

    if [ $version_int -ge 311 ]; then
        configure_args+=" --with-build-python=yes"
    fi

    ./configure $configure_args

    make -j $CPU_COUNT
    # ! INSTALL IS SERIAL, AND MAKEFLAGS IS CLEARED TO KEEP IT THAT WAY. This target
    #   installs libpython3.x.so and builds/installs extension modules that link
    #   against it, with the dependency between those two steps missing (the same
    #   class of gap the comment above describes). Run it in parallel and a module
    #   links against a libpython that is still being copied - the linker reports
    #   "section header table goes past the end of the file", which reads like a
    #   corrupt toolchain rather than a race.
    #   `-j1` alone is not enough: an inherited MAKEFLAGS still reaches sub-makes,
    #   and a caller that exports `MAKEFLAGS=-jN` (docker/build-all.sh does) turns
    #   this line parallel without touching it. That is why this failed only in the
    #   container - the bare-metal runbook never set MAKEFLAGS.
    MAKEFLAGS= make -j1 install prefix=$PREFIX

# Python 3.13 and later comes with an official Android build script.
else
    mkdir -p cross-build/build
    # Chaquopy FT patch: DISABLE_GIL=1 -> free-threaded (PEP 703) target.
    # Use the free-threaded build-python (ABI must match the host) and pass
    # --disable-gil through to the official CPython Android host configure.
    # DEFAULT FREE-THREADED (this is the 314t driver): a clean-environment run
    # proved the old default (0) silently built the stock GIL interpreter with
    # nothing but a missing lib to show for it. DISABLE_GIL=0 still gets you
    # the stock build when you genuinely want one.
    if [ "${DISABLE_GIL:-1}" = "1" ]; then
        ln -s "$(which python${version_short}t)" cross-build/build/python
        gil_args="-- --disable-gil"
    else
        ln -s "$(which python$version_short)" cross-build/build/python
        gil_args=""
    fi

    Android/android.py configure-host "$HOST" $gil_args
    # ! MAKEFLAGS IS CLEARED HERE, AND THIS IS THE LINE THAT MATTERS FOR 3.13+.
    #   android.py runs two makes: the build as `make -j <cpu_count>` (its own -j,
    #   explicit) and then `make install` with NO -j. So install is serial by design -
    #   UNLESS an exported MAKEFLAGS injects one, which docker/build-all.sh does.
    #   Parallel install races libpython against the extension modules that link to
    #   it, and the linker reports "section header table goes past the end of the
    #   file" - a truncated read, not a corrupt toolchain.
    #   Clearing MAKEFLAGS costs NOTHING: android.py passes its own -j for the build,
    #   so only the install is serialised.
    #   ** THIS IS A RACE, SO A GREEN RUN PROVES NOTHING. ** The first attempt at
    #   fixing this patched the `version_int -le 312` branch above, which 3.14 never
    #   executes, and the next run passed anyway - by luck. Two runs later it failed
    #   again, identically. Do not take one pass as evidence here.
    MAKEFLAGS= Android/android.py make-host "$HOST"
    cp -a "cross-build/$HOST/prefix/"* "$PREFIX"
fi
