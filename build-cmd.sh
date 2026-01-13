#!/usr/bin/env bash

cd "$(dirname "$0")"
top="$(pwd)"

set -eu


# Check if nproc is available, otherwise use sysctl -n hw.physicalcpu (macOS)
if command -v nproc >/dev/null 2>&1; then
    NPROC=$(nproc)
else
    NPROC=$(sysctl -n hw.physicalcpu)
fi


if [ -z "$AUTOBUILD" ] ; then
    exit 1
fi

# Libraries on which we depend - please keep alphabetized for maintenance
BOOST_LIBS=(context date_time fiber filesystem iostreams json program_options
            regex stacktrace system thread url wave)

# -d0 is quiet, "-d2 -d+4" allows compilation to be examined
BOOST_BUILD_SPAM="-d0"

BOOST_SOURCE_DIR="boost"
cd "$BOOST_SOURCE_DIR"
bjam="$(pwd)/b2"
stage="$(pwd)/stage"
VERSION_HEADER_FILE="$stage/include/boost/version.hpp"
VERSION_MACRO="BOOST_LIB_VERSION"

fail()
{
    echo "$@" >&2
    exit 1
}

[ -f "$stage"/packages/include/zlib-ng/zlib.h ] || fail "You haven't installed the zlib package yet."

if [ ! -d "libs/accumulators/include" ]; then
    echo "Submodules not present. Initializing..."
    git submodule update --init --recursive
fi

apply_patch()
{
    local patch="$1"
    local path="$2"

    # Fix paths for windows
    if [[ "$OSTYPE" == "cygwin" || "$OSTYPE" == "msys" ]] ; then
        patch="$(cygpath -m $patch)"
        path="$(cygpath -m $path)"
    fi

    echo "Applying $patch..."
    git apply --check --reverse --directory="$path" "$patch" 2>/dev/null || git apply --directory="$path" "$patch"
}

apply_patch "../patches/libs/config/0001-Define-BOOST_ALL_NO_LIB.patch" "libs/config"
apply_patch "../patches/libs/fiber/0001-DRTVWR-476-Use-WIN32_LEAN_AND_MEAN-for-each-include-.patch" "libs/fiber"

# remove_cxxstd
source "$(dirname "$AUTOBUILD_VARIABLES_FILE")/functions"

if [[ "$OSTYPE" == "cygwin" || "$OSTYPE" == "msys" ]] ; then
    autobuild="$(cygpath -u $AUTOBUILD)"
    # convert from bash path to native OS pathname
    native()
    {
        cygpath -w "$@"
    }
else
    autobuild="$AUTOBUILD"
    # no pathname conversion needed
    native()
    {
        echo "$*"
    }
fi

# load autobuild provided shell functions and variables
source_environment_tempfile="$stage/source_environment.sh"
"$autobuild" source_environment > "$source_environment_tempfile"
. "$source_environment_tempfile"

# Explicitly request each of the libraries named in BOOST_LIBS.
# Use magic bash syntax to prefix each entry in BOOST_LIBS with "--with-".
BOOST_BJAM_OPTIONS="address-model=$AUTOBUILD_ADDRSIZE cxxstd=20 --layout=tagged -sNO_BZIP2=1 -sNO_LZMA=1 -sNO_ZSTD=1 -j$AUTOBUILD_CPU_COUNT\
                    ${BOOST_LIBS[*]/#/--with-}"


# Turn these into a bash array: it's important that all of cxxflags (which
# we're about to add) go into a single array entry.
BOOST_BJAM_OPTIONS=($BOOST_BJAM_OPTIONS)
# Append cxxflags as a single entry containing all of LL_BUILD_RELEASE.

case "$AUTOBUILD_PLATFORM" in
    windows*)
        BOOST_BJAM_OPTIONS+=("cxxflags=$(replace_switch /Zi /Z7 $LL_BUILD_RELEASE)")
    ;;
    *)
        BOOST_BJAM_OPTIONS+=("cxxflags=$LL_BUILD_RELEASE")
    ;;
esac



stage_lib="${stage}"/lib
stage_release="${stage_lib}"/release
mkdir -p "${stage_release}"

# Restore all .sos
restore_sos ()
{
    for solib in "${stage}"/packages/lib/debug/libz.so*.disable "${stage}"/packages/lib/release/libz.so*.disable; do
        if [ -f "$solib" ]; then
            mv -f "$solib" "${solib%.disable}"
        fi
    done
}

# Restore all .dylibs
restore_dylibs ()
{
    for dylib in "$stage/packages/lib"/{debug,release}/*.dylib.disable; do
        if [ -f "$dylib" ]; then
            mv "$dylib" "${dylib%.disable}"
        fi
    done
}

find_test_jamfile_dir_for()
{
    # Not every Boost library contains a libs/x/test/Jamfile.v2 file. Some
    # have libs/x/test/build/Jamfile.v2. Some have more than one test
    # subdirectory with a Jamfile. Try to be general about it.
    # You can't use bash 'read' from a pipe, though truthfully I've always
    # wished that worked. What you *can* do is read from redirected stdin, but
    # that must follow 'done'.
    while read path
    do # caller doesn't want the actual Jamfile name, just its directory
       dirname "$path"
    done < <(find libs/$1/test -name 'Jam????*' -type f -print)
    # Credit to https://stackoverflow.com/a/11100252/5533635 for the
    # < <(command) trick. Empirically, it does iterate 0 times on empty input.
}

find_test_dirs()
{
    # Pass in the libraries of interest. This shell function emits to stdout
    # the corresponding set of test directories, one per line: the specific
    # library directories containing the Jamfiles of interest. Passing each of
    # these directories to bjam should cause it to build and run that set of
    # tests.
    for blib
    do
        find_test_jamfile_dir_for "$blib"
    done
}

# pipeline stage between find_test_dirs and run_tests to eliminate tests for
# specified libraries
function tfilter {
    local regexps=()
    for arg
    do
        regexps+=(-e "$arg")
    done
    grep -v "${regexps[@]}"
}

# Try running some tests on Windows64, just not on Windows32.
if [[ $AUTOBUILD_ADDRSIZE -ne 32 ]]
then
    function tfilter32 {
        cat -
    }
else
    function tfilter32 {
        tfilter "$@"
    }
fi

# conditionally run unit tests
run_tests()
{
    # This shell function wants to accept two different sets of arguments,
    # each of arbitrary length: the list of library test directories, and the
    # list of bjam arguments for each test. Since we don't have a good way to
    # do that in bash, we read library test directories from stdin, one per
    # line; command-line arguments are simply forwarded to the bjam command.
    if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
        # read individual directories from stdin below
        while read testdir
        do  sep "$testdir"
            # link=static
            "${bjam}" "$testdir" "$@"
        done < /dev/stdin
    fi
    return 0
}

case "$AUTOBUILD_PLATFORM" in
    windows*)
        # To reliably use python3 on windows we need to use the python launcher
        PYTHON=${PYTHON:-py -3}
        ;;
esac
PYTHON="${PYTHON:-python3}"

last_file="$(mktemp -t build-cmd.XXXXXXXX)"
trap "rm '$last_file'" EXIT
# from here on, the only references to last_file will be from Python
last_file="$(native "$last_file")"
last_time="$($PYTHON -uc "import os.path; print(int(os.path.getmtime(r'$last_file')))")"
start_time="$last_time"


sep()
{
    $PYTHON "$(native "$top")/timestamp.py" "$start_time" "$last_file" "$@"
}

case "$AUTOBUILD_PLATFORM" in

    windows*)

        # Setup boost context arch flags
        mkdir -p "build_release_sse"
        pushd "build_release_sse"
            opts="$(replace_switch /Zi /Z7 $LL_BUILD_RELEASE)"
            plainopts="$(remove_switch /GR $(remove_cxxstd $opts))"

            cmake -G "$AUTOBUILD_WIN_CMAKE_GEN" -A "$AUTOBUILD_WIN_VSPLATFORM" $(cygpath -m "$top/$BOOST_SOURCE_DIR") -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF \
                    -DCMAKE_CONFIGURATION_TYPES="Release" \
                    -DCMAKE_C_FLAGS="$plainopts" \
                    -DCMAKE_CXX_FLAGS="$opts /EHsc" \
                    -DCMAKE_MSVC_DEBUG_INFORMATION_FORMAT="Embedded" \
                    -DCMAKE_INSTALL_PREFIX="$(cygpath -m $stage)" \
                    -DCMAKE_INSTALL_LIBDIR="$(cygpath -m "$stage/lib/release")" \
                    -DCMAKE_INSTALL_INCLUDEDIR="$(cygpath -m "$stage/include")" \
                    -DBOOST_INSTALL_LAYOUT="system" \
                    -DBOOST_ENABLE_MPI=OFF \
                    -DBOOST_ENABLE_PYTHON=OFF \
                    -DBOOST_CONTEXT_ARCHITECTURE="x86_64" \
                    -DBOOST_CONTEXT_ABI="ms" \
                    -DBOOST_IOSTREAMS_ENABLE_BZIP2=OFF \
                    -DBOOST_IOSTREAMS_ENABLE_LZMA=OFF \
                    -DBOOST_IOSTREAMS_ENABLE_ZLIB=OFF \
                    -DBOOST_IOSTREAMS_ENABLE_ZSTD=OFF \
                    -DBOOST_LOCALE_ENABLE_ICU=OFF

            cmake --build . --config Release --parallel $AUTOBUILD_CPU_COUNT
            cmake --install . --config Release

            # conditionally run unit tests
            # if [[ "${DISABLE_UNIT_TESTS:-0}" == "0" ]]; then
            #     ctest -C Release --parallel $AUTOBUILD_CPU_COUNT
            # fi
        popd

        # Move the libs
        #mv "${stage_lib}"/*.lib "${stage_release}"

        # cmake doesn't need vsvars, but our hand compilation does
        load_vsvars

        # populate version_file
        sep "version"
        cl -DVERSION_HEADER_FILE="\"$(cygpath -w $VERSION_HEADER_FILE)\"" \
           -DVERSION_MACRO="$VERSION_MACRO" \
           -Fo"$(cygpath -w "$stage/version.obj")" \
           -Fe"$(cygpath -w "$stage/version.exe")" \
           "$(cygpath -w "$top/version.c")"
        # Boost's VERSION_MACRO emits (e.g.) "1_55"
        "$stage/version.exe" | tr '_' '.' > "$stage/version.txt"
        rm "$stage"/version.{obj,exe}
        ;;

    darwin*)
        # deploy target
        export MACOSX_DEPLOYMENT_TARGET=${LL_BUILD_DARWIN_DEPLOY_TARGET}

        for arch in x86_64 arm64 ; do
            ARCH_ARGS="-arch $arch"
            cxx_opts="${TARGET_OPTS:-$ARCH_ARGS $LL_BUILD_RELEASE}"
            cc_opts="$(remove_cxxstd $cxx_opts)"
            ld_opts="$ARCH_ARGS"

            # Setup boost context arch flags
            if [[ "$arch" == "x86_64" ]]; then
                BOOST_CONTEXT_ARCH="x86_64"
                BOOST_CONTEXT_ABI="sysv"
            elif [[ "$arch" == "arm64" ]]; then
                BOOST_CONTEXT_ARCH="arm64"
                BOOST_CONTEXT_ABI="aapcs"
            fi

            mkdir -p "build_$arch"
            pushd "build_$arch"
                CFLAGS="$cc_opts" \
                CXXFLAGS="$cxx_opts" \
                LDFLAGS="$ld_opts" \
                cmake $top/$BOOST_SOURCE_DIR -G "Xcode" -DBUILD_SHARED_LIBS:BOOL=OFF -DBUILD_TESTING=OFF \
                    -DCMAKE_CONFIGURATION_TYPES="Release" \
                    -DCMAKE_C_FLAGS="$cc_opts" \
                    -DCMAKE_CXX_FLAGS="$cxx_opts" \
                    -DCMAKE_INSTALL_PREFIX="$stage" \
                    -DCMAKE_INSTALL_LIBDIR="$stage/lib/release/$arch" \
                    -DCMAKE_INSTALL_INCLUDEDIR="$stage/include" \
                    -DCMAKE_OSX_ARCHITECTURES="$arch" \
                    -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET} \
                    -DBOOST_INSTALL_LAYOUT="system" \
                    -DBOOST_ENABLE_MPI=OFF \
                    -DBOOST_ENABLE_PYTHON=OFF \
                    -DBOOST_CONTEXT_ARCHITECTURE=$BOOST_CONTEXT_ARCH \
                    -DBOOST_CONTEXT_ABI="$BOOST_CONTEXT_ABI" \
                    -DBOOST_IOSTREAMS_ENABLE_BZIP2=OFF \
                    -DBOOST_IOSTREAMS_ENABLE_LZMA=OFF \
                    -DBOOST_IOSTREAMS_ENABLE_ZLIB=OFF \
                    -DBOOST_IOSTREAMS_ENABLE_ZSTD=OFF \
                    -DBOOST_LOCALE_ENABLE_ICU=OFF

                cmake --build . --config Release --parallel $AUTOBUILD_CPU_COUNT
                cmake --install . --config Release

                # conditionally run unit tests
                # if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                #     ctest -C Release --parallel $AUTOBUILD_CPU_COUNT
                # fi
            popd
        done

        # create release universal libs
        lipo -create -output ${stage_release}/libboost_atomic.a ${stage_release}/x86_64/libboost_atomic.a ${stage_release}/arm64/libboost_atomic.a
        lipo -create -output ${stage_release}/libboost_charconv.a ${stage_release}/x86_64/libboost_charconv.a ${stage_release}/arm64/libboost_charconv.a
        lipo -create -output ${stage_release}/libboost_chrono.a ${stage_release}/x86_64/libboost_chrono.a ${stage_release}/arm64/libboost_chrono.a
        lipo -create -output ${stage_release}/libboost_cobalt.a ${stage_release}/x86_64/libboost_cobalt.a ${stage_release}/arm64/libboost_cobalt.a
        lipo -create -output ${stage_release}/libboost_container.a ${stage_release}/x86_64/libboost_container.a ${stage_release}/arm64/libboost_container.a
        lipo -create -output ${stage_release}/libboost_context.a ${stage_release}/x86_64/libboost_context.a ${stage_release}/arm64/libboost_context.a
        lipo -create -output ${stage_release}/libboost_contract.a ${stage_release}/x86_64/libboost_contract.a ${stage_release}/arm64/libboost_contract.a
        lipo -create -output ${stage_release}/libboost_coroutine.a ${stage_release}/x86_64/libboost_coroutine.a ${stage_release}/arm64/libboost_coroutine.a
        lipo -create -output ${stage_release}/libboost_date_time.a ${stage_release}/x86_64/libboost_date_time.a ${stage_release}/arm64/libboost_date_time.a
        lipo -create -output ${stage_release}/libboost_fiber_numa.a ${stage_release}/x86_64/libboost_fiber_numa.a ${stage_release}/arm64/libboost_fiber_numa.a
        lipo -create -output ${stage_release}/libboost_fiber.a ${stage_release}/x86_64/libboost_fiber.a ${stage_release}/arm64/libboost_fiber.a
        lipo -create -output ${stage_release}/libboost_filesystem.a ${stage_release}/x86_64/libboost_filesystem.a ${stage_release}/arm64/libboost_filesystem.a
        lipo -create -output ${stage_release}/libboost_graph.a ${stage_release}/x86_64/libboost_graph.a ${stage_release}/arm64/libboost_graph.a
        lipo -create -output ${stage_release}/libboost_iostreams.a ${stage_release}/x86_64/libboost_iostreams.a ${stage_release}/arm64/libboost_iostreams.a
        lipo -create -output ${stage_release}/libboost_json.a ${stage_release}/x86_64/libboost_json.a ${stage_release}/arm64/libboost_json.a
        lipo -create -output ${stage_release}/libboost_locale.a ${stage_release}/x86_64/libboost_locale.a ${stage_release}/arm64/libboost_locale.a
        lipo -create -output ${stage_release}/libboost_log_setup.a ${stage_release}/x86_64/libboost_log_setup.a ${stage_release}/arm64/libboost_log_setup.a
        lipo -create -output ${stage_release}/libboost_log.a ${stage_release}/x86_64/libboost_log.a ${stage_release}/arm64/libboost_log.a
        lipo -create -output ${stage_release}/libboost_nowide.a ${stage_release}/x86_64/libboost_nowide.a ${stage_release}/arm64/libboost_nowide.a
        lipo -create -output ${stage_release}/libboost_prg_exec_monitor.a ${stage_release}/x86_64/libboost_prg_exec_monitor.a ${stage_release}/arm64/libboost_prg_exec_monitor.a
        lipo -create -output ${stage_release}/libboost_process.a ${stage_release}/x86_64/libboost_process.a ${stage_release}/arm64/libboost_process.a
        lipo -create -output ${stage_release}/libboost_program_options.a ${stage_release}/x86_64/libboost_program_options.a ${stage_release}/arm64/libboost_program_options.a
        lipo -create -output ${stage_release}/libboost_random.a ${stage_release}/x86_64/libboost_random.a ${stage_release}/arm64/libboost_random.a
        lipo -create -output ${stage_release}/libboost_serialization.a ${stage_release}/x86_64/libboost_serialization.a ${stage_release}/arm64/libboost_serialization.a
        lipo -create -output ${stage_release}/libboost_stacktrace_addr2line.a ${stage_release}/x86_64/libboost_stacktrace_addr2line.a ${stage_release}/arm64/libboost_stacktrace_addr2line.a
        lipo -create -output ${stage_release}/libboost_stacktrace_basic.a ${stage_release}/x86_64/libboost_stacktrace_basic.a ${stage_release}/arm64/libboost_stacktrace_basic.a
        lipo -create -output ${stage_release}/libboost_stacktrace_noop.a ${stage_release}/x86_64/libboost_stacktrace_noop.a ${stage_release}/arm64/libboost_stacktrace_noop.a
        lipo -create -output ${stage_release}/libboost_test_exec_monitor.a ${stage_release}/x86_64/libboost_test_exec_monitor.a ${stage_release}/arm64/libboost_test_exec_monitor.a
        lipo -create -output ${stage_release}/libboost_thread.a ${stage_release}/x86_64/libboost_thread.a ${stage_release}/arm64/libboost_thread.a
        lipo -create -output ${stage_release}/libboost_timer.a ${stage_release}/x86_64/libboost_timer.a ${stage_release}/arm64/libboost_timer.a
        lipo -create -output ${stage_release}/libboost_type_erasure.a ${stage_release}/x86_64/libboost_type_erasure.a ${stage_release}/arm64/libboost_type_erasure.a
        lipo -create -output ${stage_release}/libboost_unit_test_framework.a ${stage_release}/x86_64/libboost_unit_test_framework.a ${stage_release}/arm64/libboost_unit_test_framework.a
        lipo -create -output ${stage_release}/libboost_url.a ${stage_release}/x86_64/libboost_url.a ${stage_release}/arm64/libboost_url.a
        lipo -create -output ${stage_release}/libboost_wave.a ${stage_release}/x86_64/libboost_wave.a ${stage_release}/arm64/libboost_wave.a
        lipo -create -output ${stage_release}/libboost_wserialization.a ${stage_release}/x86_64/libboost_wserialization.a ${stage_release}/arm64/libboost_wserialization.a

        # populate version_file
        sep "version"
        cc -DVERSION_HEADER_FILE="\"$VERSION_HEADER_FILE\"" \
           -DVERSION_MACRO="$VERSION_MACRO" \
           -o "$stage/version" "$top/version.c"
        # Boost's VERSION_MACRO emits (e.g.) "1_55"
        "$stage/version" | tr '_' '.' > "$stage/version.txt"
        rm "$stage/version"
        ;;

    linux*)
        cxx_opts="$LL_BUILD_RELEASE"
        cc_opts="$(remove_cxxstd $cxx_opts)"

        mkdir -p "build_release"
        pushd "build_release"
            CFLAGS="$cc_opts" \
            CXXFLAGS="$cxx_opts" \
            cmake $top/$BOOST_SOURCE_DIR -G "Ninja" -DBUILD_SHARED_LIBS:BOOL=OFF -DBUILD_TESTING=OFF \
                -DCMAKE_BUILD_TYPE="Release" \
                -DCMAKE_C_FLAGS="$cc_opts" \
                -DCMAKE_CXX_FLAGS="$cxx_opts" \
                -DCMAKE_INSTALL_PREFIX="$stage" \
                -DCMAKE_INSTALL_LIBDIR="$stage/lib/release" \
                -DCMAKE_INSTALL_INCLUDEDIR="$stage/include" \
                -DBOOST_INSTALL_LAYOUT="system" \
                -DBOOST_ENABLE_MPI=OFF \
                -DBOOST_ENABLE_PYTHON=OFF \
                -DBOOST_IOSTREAMS_ENABLE_BZIP2=OFF \
                -DBOOST_IOSTREAMS_ENABLE_LZMA=OFF \
                -DBOOST_IOSTREAMS_ENABLE_ZLIB=OFF \
                -DBOOST_IOSTREAMS_ENABLE_ZSTD=OFF \
                -DBOOST_LOCALE_ENABLE_ICU=OFF

            cmake --build . --config Release --parallel $AUTOBUILD_CPU_COUNT
            cmake --install . --config Release

            # conditionally run unit tests
            # if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
            #     ctest -C Release --parallel $AUTOBUILD_CPU_COUNT
            # fi
        popd

        # populate version_file
        sep "version"
        cc -DVERSION_HEADER_FILE="\"$VERSION_HEADER_FILE\"" \
           -DVERSION_MACRO="$VERSION_MACRO" \
           -o "$stage/version" "$top/version.c"
        # Boost's VERSION_MACRO emits (e.g.) "1_55"
        "$stage/version" | tr '_' '.' > "$stage/version.txt"
        rm "$stage/version"
        ;;
esac

sep "includes and text"
mkdir -p "${stage}"/LICENSES
cp -a LICENSE_1_0.txt "${stage}"/LICENSES/boost.txt
