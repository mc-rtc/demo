#!/usr/bin/env bash

set -euxo pipefail

readonly this_dir=`cd $(dirname $0); pwd`
readonly artifacts_dir=$this_dir/artifacts
readonly build_dir=$this_dir/build
readonly src_dir=$this_dir/src

mkdir -p $artifacts_dir
mkdir -p $build_dir
mkdir -p $src_dir

# Install pre-requisites packages
sudo apt-get install -y build-essential

echo "::group::Install CMake"
if [ ! -f $this_dir/cmake/bin/cmake ]
then
  cd $this_dir
  wget --quiet https://github.com/Kitware/CMake/releases/download/v3.18.4/cmake-3.18.4-Linux-x86_64.tar.gz
  tar xzf cmake-3.18.4-Linux-x86_64.tar.gz
  rm -f cmake-3.18.4-Linux-x86_64.tar.gz
  mv cmake-3.18.4-Linux-x86_64 cmake
fi
export CMAKE=$this_dir/cmake/bin/cmake
if [ ! -f $CMAKE ]
then
  echo "CMake installation went wrong" && false
fi
$CMAKE --version
echo "::endgroup::"

echo "::group::Install emscripten"
if [ ! -d $this_dir/emsdk ]
then
  cd $this_dir
  git clone https://github.com/emscripten-core/emsdk.git
fi
if [ ! -f $this_dir/emsdk/upstream/emscripten/emcc ]
then
  cd $this_dir/emsdk
  ./emsdk install latest
  ./emsdk activate latest
fi
source $this_dir/emsdk/emsdk_env.sh
export EM_PREFIX=$EMSDK/upstream/emscripten/system
echo "::endgroup::"

export FORCE_JRL_CMAKEMODULES_UPDATE=false

# Helper function to build a CMake project
build_cmake_project()
{
  name=$1
  src=$2
  # FIXME Work around for project that use jrl-cmakemodules but don't have jrl-cmakemodules#459
  if $FORCE_JRL_CMAKEMODULES_UPDATE && [ -d $src/cmake ]
  then
    cd $src/cmake
    git pull origin master
  fi
  # FIXME Patch for Tasks
  if [ $name == "Tasks" ]
  then
    cd $src
    sed -i -e's/add_definitions(-mfpmath=sse -msse2)//' CMakeLists.txt
  fi
  mkdir -p $build_dir/$name
  cd $build_dir/$name
  emcmake $CMAKE $src -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE} -DCMAKE_INSTALL_PREFIX=${EM_PREFIX} ${CMAKE_OPTIONS}
  emmake make -j$(nproc)
  emmake make install
}

# Helper to build from git
build_git()
{
  echo "::group::Install $1"
  name=$1
  uri=$2
  branch=$3
  if [ ! -d $src_dir/$name ]
  then
    cd $src_dir
    git clone --recursive $uri $src_dir/$name
    cd $src_dir/$name
    git checkout origin/$branch -B $branch || git checkout $branch -B $branch
    git submodule sync --recursive && git submodule update --init --recursive
  fi
  build_cmake_project $name $src_dir/$name
  echo "::endgroup::"
}

# Helper to build from a GitHub project
build_github()
{
  build_git `basename $1` https://github.com/$1 $2
}

# Helper to build from a tarball
build_release()
{
  echo "::group::Install $1"
  name=$1
  folder=$2
  uri=$3
  if [ ! -d $src_dir/$folder ]
  then
    cd $src_dir
    wget --quiet $uri -O - | tar -xz
  fi
  build_cmake_project $name $src_dir/$folder
  echo "::endgroup::"
}

echo "::group::Install Boost 1.74.0"
if [ ! -d $src_dir/boost_1_74_0 ]
then
  cd $src_dir
  wget --quiet https://dl.bintray.com/boostorg/release/1.74.0/source/boost_1_74_0.tar.bz2
  tar xjf boost_1_74_0.tar.bz2
  rm -f boost_1_74_0.tar.bz2
fi
cd $src_dir/boost_1_74_0
if [ ! -f ./b2 ]
then
  ./bootstrap.sh || (cat bootstrap.log && false)
fi

# Options
export CMAKE_BUILD_TYPE=Release
export CXXFLAGS="-matomics -s USE_PTHREADS=1 -s DISABLE_EXCEPTION_CATCHING=0"
export LDFLAGS="-s USE_PTHREADS=1 -s DISABLE_EXCEPTION_CATCHING=0"

# Copy our patched jam configuration
cp $this_dir/emscripten.jam tools/build/src/tools/
emconfigure ./b2 toolset=emscripten --with-filesystem --with-timer --with-program_options --with-system --with-serialization --prefix=$EM_PREFIX variant=release link=static install
echo "::endgroup::"

# Build f2c
echo "::group::Install libf2c"
if [ ! -d $src_dir/libf2c-emscripten ]
then
  cd $src_dir
  git clone https://github.com/gergondet/libf2c-emscripten.git libf2c-emscripten
fi
cd $src_dir/libf2c-emscripten
emmake make -j$(nproc)
emmake make install
echo "::endgroup::"

# Build other dependencies

export CMAKE_OPTIONS="-DBUILD_TESTING=OFF"
build_release eigen eigen-git-mirror-3.3.7 https://github.com/eigenteam/eigen-git-mirror/archive/3.3.7.tar.gz

build_release tinyxml2 tinyxml2-7.1.0 https://github.com/leethomason/tinyxml2/archive/7.1.0.tar.gz

export CMAKE_OPTIONS="-DBUILD_SHARED_LIBS=OFF -DASSIMP_BUILD_ALL_EXPORTERS_BY_DEFAULT=OFF -DASSIMP_BUILD_ALL_IMPORTERS_BY_DEFAULT=OFF -DASSIMP_BUILD_COLLADA_IMPORTER=ON -DASSIMP_BUILD_STL_IMPORTER=ON -DASSIMP_BUILD_ASSIMP_TOOLS=OFF -DASSIMP_BUILD_TESTS=OFF"
build_release assimp assimp-5.0.1 https://github.com/assimp/assimp/archive/v5.0.1.tar.gz

export CMAKE_OPTIONS="-DBUILD_TESTING=OFF -DBUILD_DOCUMENTATION=OFF -DBUILD_SHARED_LIBS=OFF -DDISABLE_GEOS_INLINE=ON"
build_github libgeos/geos master

export CMAKE_OPTIONS="-DYAML_CPP_BUILD_TESTS=OFF"
build_release yaml-cpp yaml-cpp-yaml-cpp-0.6.3 https://github.com/jbeder/yaml-cpp/archive/yaml-cpp-0.6.3.tar.gz

export CMAKE_OPTIONS="-DSPDLOG_BUILD_TESTS=OFF -DSPDLOG_BUILD_SHARED=OFF"
build_release spdlog spdlog-1.6.1 https://github.com/gabime/spdlog/archive/v1.6.1.tar.gz

export CMAKE_OPTIONS="-DBUILD_TESTING=OFF -DBUILD_PYTHON_INTERFACE=OFF -DINSTALL_DOCUMENTATION=OFF"
build_github humanoid-path-planner/hpp-spline v4.7.0

export FORCE_JRL_CMAKEMODULES_UPDATE=true

export CMAKE_OPTIONS="-DBUILD_TESTING=OFF -DPYTHON_BINDING=OFF -DUSE_F2C=ON -DINSTALL_DOCUMENTATION=OFF"
build_github jrl-umi3218/SpaceVecAlg master
build_github jrl-umi3218/sch-core master
build_github jrl-umi3218/eigen-qld master
# FIXME Change the source when RBDyn#76 is merged
build_github gergondet/RBDyn topic/LoadMaterial
build_github jrl-umi3218/Tasks master
build_github jrl-umi3218/mc_rbdyn_urdf master
build_github jrl-umi3218/mc_rtc_data master
build_github jrl-umi3218/eigen-quadprog master

export CMAKE_OPTIONS="${CMAKE_OPTIONS} -DDISABLE_ROS=ON -DMC_RTC_BUILD_STATIC=ON -DMC_RTC_DISABLE_NETWORK=ON"
build_github gergondet/mc_rtc topic/wasm

build_github gergondet/mc_rtc-raylib master
cp $build_dir/mc_rtc-raylib/index.* $artifacts_dir/
