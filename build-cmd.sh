#!/usr/bin/env bash

cd "$(dirname "$0")"
top="$(pwd)"

set -eu

BOOST_SOURCE_DIR="boost"
VERSION_HEADER_FILE="$BOOST_SOURCE_DIR/boost/version.hpp"
VERSION_MACRO="BOOST_LIB_VERSION"

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

cd "$BOOST_SOURCE_DIR"
bjam="$(pwd)/b2"
stage="$(pwd)/stage"

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
    echo "Applying $patch..."
    git apply --check --reverse --directory="$path" "$patch" || git apply --directory="$path" "$patch"
}

apply_patch "../patches/libs/config/0001-Define-BOOST_ALL_NO_LIB.patch" "libs/config"
apply_patch "../patches/libs/fiber/0001-DRTVWR-476-Use-WIN32_LEAN_AND_MEAN-for-each-include-.patch" "libs/fiber"

if [ "$OSTYPE" = "cygwin" ] ; then
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
BOOST_BJAM_OPTIONS="address-model=$AUTOBUILD_ADDRSIZE architecture=x86 --layout=tagged -sNO_BZIP2=1 -sNO_LZMA=1 -sNO_ZSTD=1 -j$NPROC\
                    ${BOOST_LIBS[*]/#/--with-}"


# Turn these into a bash array: it's important that all of cxxflags (which
# we're about to add) go into a single array entry.
BOOST_BJAM_OPTIONS=($BOOST_BJAM_OPTIONS)
# Append cxxflags as a single entry containing all of LL_BUILD_RELEASE.
BOOST_BJAM_OPTIONS+=("cxxflags=$LL_BUILD_RELEASE")

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

# bjam doesn't support a -sICU_LIBPATH to point to the location
# of the icu libraries like it does for zlib. Instead, it expects
# the library files to be immediately in the ./lib directory
# and the headers to be in the ./include directory and doesn't
# provide a way to work around this. Because of this, we break
# the standard packaging layout, with the debug library files
# in ./lib/debug and the release in ./lib/release and instead
# only package the release build of icu4c in the ./lib directory.
# If a way to work around this is found, uncomment the
# corresponding blocks in the icu4c build and fix it here.

case "$AUTOBUILD_PLATFORM" in

    windows*)
        INCLUDE_PATH="$(native "${stage}"/packages/include)"
        ZLIB_RELEASE_PATH="$(native "${stage}"/packages/lib/release)"
        ICU_PATH="$(native "${stage}"/packages)"

        if [[ -z "$AUTOBUILD_WIN_VSTOOLSET" ]]
        then
            # lifted from autobuild_tool_source_environment.py
            declare -A toolsets=(
                ["14"]=v140
                ["15"]=v141
                ["16"]=v142
                ["17"]=v143
            )
            AUTOBUILD_WIN_VSTOOLSET="${toolsets[${AUTOBUILD_VSVER:0:2}]}"
            if [[ -z "$AUTOBUILD_WIN_VSTOOLSET" ]]
            then
                echo "Can't guess AUTOBUILD_WIN_VSTOOLSET from AUTOBUILD_VSVER='$AUTOBUILD_VSVER'" >&2
                exit 1
            fi
        fi

        # e.g. "v141", want just "141"
        toolset="${AUTOBUILD_WIN_VSTOOLSET#v}"
        # e.g. "vc14"
        bootstrapver="vc${toolset%1}"
        # e.g. "msvc-14.1"
        bjamtoolset="msvc-${toolset:0:2}.${toolset:2}"

        sep "bootstrap"
        # Odd things go wrong with the .bat files:  branch targets
        # not recognized, file tests incorrect.  Inexplicable but
        # dropping 'echo on' into the .bat files seems to help.
##        cmd.exe /C bootstrap.bat "$bootstrapver" || echo bootstrap failed 1>&2
        # Try letting bootstrap.bat infer the tooset version.
        cmd.exe /C bootstrap.bat msvc || echo bootstrap failed 1>&2
        # Failure of this bootstrap.bat file may or may not produce nonzero rc
        # -- check for the program it should have built.
        if [ ! -x "$bjam.exe" ]
        then cat "bootstrap.log"
             exit 1
        fi

        # Windows build of viewer expects /Zc:wchar_t-, etc., from LL_BUILD_RELEASE.
        # Without --hash, some compilations fail with:
        # failed to write output file 'some\long\path\something.rsp'!
        # Without /FS, some compilations fail with:
        # fatal error C1041: cannot open program database '...\vc120.pdb';
        # if multiple CL.EXE write to the same .PDB file, please use /FS
        # BOOST_STACKTRACE_LINK (not _DYN_LINK) requests external library:
        # https://www.boost.org/doc/libs/release/doc/html/stacktrace/configuration_and_build.html
        # This helps avoid macro collisions in consuming source files:
        # https://github.com/boostorg/stacktrace/issues/76#issuecomment-489347839
        WINDOWS_BJAM_OPTIONS=(-j$(nproc)
            --hash
            "include=$INCLUDE_PATH" "-sICU_PATH=$ICU_PATH"
            "-sZLIB_INCLUDE=$INCLUDE_PATH/zlib-ng"
            cxxflags=/FS
            cxxflags=/DBOOST_STACKTRACE_LINK
            "${BOOST_BJAM_OPTIONS[@]}")

        RELEASE_BJAM_OPTIONS=("${WINDOWS_BJAM_OPTIONS[@]}"
            "-sZLIB_LIBPATH=$ZLIB_RELEASE_PATH"
            "-sZLIB_LIBRARY_PATH=$ZLIB_RELEASE_PATH"
            "-sZLIB_NAME=zlib")
        sep "build"
        "${bjam}" link=static variant=release \
            --prefix="$(native "${stage}")" --libdir="$(native "${stage_release}")" \
            "${RELEASE_BJAM_OPTIONS[@]}" $BOOST_BUILD_SPAM stage

        # Constraining Windows unit tests to link=static produces unit-test
        # link errors. While it may be possible to edit the test/Jamfile.v2
        # logic in such a way as to succeed statically, it's simpler to allow
        # dynamic linking for test purposes. However -- with dynamic linking,
        # some test executables expect to implicitly load a couple of ICU
        # DLLs. But our installed ICU doesn't even package those DLLs!
        # TODO: Does this clutter our eventual tarball, or are the extra Boost
        # DLLs in a separate build directory?
        # In any case, we still observe failures in certain libraries' unit
        # tests. Certain libraries depend on ICU; thread tests are so deeply
        # nested that even with --abbreviate-paths, the .rsp file pathname is
        # too long for Windows. Poor sad broken Windows.

        # conditionally run unit tests
        find_test_dirs "${BOOST_LIBS[@]}" | \
        tfilter32 'fiber/' | \
        tfilter \
            'date_time/' \
            'filesystem/' \
            'iostreams/' \
            'regex/' \
            'stacktrace/' \
            'thread/' \
            | \
        run_tests variant=release \
                  --prefix="$(native "${stage}")" --libdir="$(native "${stage_release}")" \
                  $RELEASE_BJAM_OPTIONS $BOOST_BUILD_SPAM -a -q

        # Move the libs
        mv "${stage_lib}"/*.lib "${stage_release}"

        sep "version"
        # bjam doesn't need vsvars, but our hand compilation does
        load_vsvars

        # populate version_file
        cl /DVERSION_HEADER_FILE="\"$VERSION_HEADER_FILE\"" \
           /DVERSION_MACRO="$VERSION_MACRO" \
           /Fo"$(native "$stage/version.obj")" \
           /Fe"$(native "$stage/version.exe")" \
           "$(native "$top/version.c")"
        # Boost's VERSION_MACRO emits (e.g.) "1_55"
        "$stage/version.exe" | tr '_' '.' > "$stage/version.txt"
        rm "$stage"/version.{obj,exe}
        ;;

    darwin*)
        # Force zlib static linkage by moving .dylibs out of the way
        trap restore_dylibs EXIT
        for dylib in "${stage}"/packages/lib/{debug,release}/*.dylib; do
            if [ -f "$dylib" ]; then
                mv "$dylib" "$dylib".disable
            fi
        done

        sep "bootstrap"
        stage_lib="${stage}"/lib
        ./bootstrap.sh --prefix=$(pwd) --with-icu="${stage}"/packages

        DARWIN_BJAM_OPTIONS=("${BOOST_BJAM_OPTIONS[@]}"
            "include=${stage}/packages/include"
            "include=${stage}/packages/include/zlib-ng/"
            "-sZLIB_INCLUDE=${stage}/packages/include/zlib-ng/"
            "--disable-icu"
            cxxflags=-std=c++17)

        RELEASE_BJAM_OPTIONS=("${DARWIN_BJAM_OPTIONS[@]}"
            "-sZLIB_LIBPATH=${stage}/packages/lib/release")

        sep "build"
        "${bjam}" toolset=darwin variant=release "${RELEASE_BJAM_OPTIONS[@]}" $BOOST_BUILD_SPAM stage

        # run unit tests, excluding a few with known issues
        find_test_dirs "${BOOST_LIBS[@]}" | \
        tfilter \
            'date_time/' \
            'filesystem/test/issues' \
            'regex/test/de_fuzz' \
            'stacktrace/' \
            'wave/' \
            | \
        run_tests toolset=darwin variant=release -a -q \
                  "${RELEASE_BJAM_OPTIONS[@]}" $BOOST_BUILD_SPAM \
                  cxxflags="-DBOOST_TIMER_ENABLE_DEPRECATED"

        mv "${stage_lib}"/*.a "${stage_release}"

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
        # Force static linkage to libz by moving .sos out of the way
        trap restore_sos EXIT
        for solib in "${stage}"/packages/lib/debug/libz.so* "${stage}"/packages/lib/release/libz.so*; do
            if [ -f "$solib" ]; then
                mv -f "$solib" "$solib".disable
            fi
        done

        sep "bootstrap"
        ./bootstrap.sh --prefix=$(pwd) --with-icu="${stage}"/packages/

        RELEASE_BOOST_BJAM_OPTIONS=(toolset=gcc "include=$stage/packages/include/zlib-ng/"
            "-sZLIB_LIBPATH=$stage/packages/lib/release"
            "-sZLIB_INCLUDE=${stage}\/packages/include/zlib/"
            "${BOOST_BJAM_OPTIONS[@]}"
            cxxflags=-std=c++17)
        sep "build"
        "${bjam}" variant=release --reconfigure \
            --prefix="${stage}" --libdir="${stage}"/lib/release \
            "${RELEASE_BOOST_BJAM_OPTIONS[@]}" $BOOST_BUILD_SPAM stage

        mv "${stage_lib}"/libboost* "${stage_release}"

        sep "clean"
        "${bjam}" --clean

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
mkdir -p "${stage}"/include
cp -aL boost "${stage}"/include/
mkdir -p "${stage}"/LICENSES
cp -a LICENSE_1_0.txt "${stage}"/LICENSES/boost.txt
mkdir -p "${stage}"/docs/boost/

cd "$top"
