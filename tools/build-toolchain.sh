#!/bin/sh
# Сборка тулчейна для стенда: e2k-linux-gnu-{as,ld,objdump} и qemu-e2k
# (linux-user) с патчем на запись регистров стеков. Использование:
#   sh tools/build-toolchain.sh <prefix>      (например /opt/e2k)
set -eu
PREFIX=${1:-/opt/e2k}
HERE=$(cd "$(dirname "$0")" && pwd)
PATCH=$HERE/qemu-e2k-user-hwstacks.patch
WORK=$(mktemp -d)
JOBS=$(nproc 2>/dev/null || echo 4)

git clone -q --depth 1 -b binutils-mcst-2.41 https://github.com/OpenE2K/binutils-gdb "$WORK/binutils"
mkdir -p "$WORK/build-binutils" && cd "$WORK/build-binutils"
"$WORK/binutils/configure" --target=e2k-linux-gnu --prefix="$PREFIX" \
    --disable-gdb --disable-gdbserver --disable-sim --disable-libdecnumber \
    --disable-readline --disable-nls --disable-werror MAKEINFO=true > configure.log
make -j"$JOBS" all-gas all-ld all-binutils > make.log
make install-gas install-ld install-binutils > install.log

# qemu-e2k: ветка e2k, состояние ebc4bbd (на нём проверен патч)
QEMU_SHA=ebc4bbdbe5d74bbf5a59784f697a6df64a9aa299
mkdir -p "$WORK/qemu-e2k" && cd "$WORK/qemu-e2k"
git init -q && git remote add origin https://github.com/OpenE2K/qemu-e2k
git fetch -q --depth 1 origin "$QEMU_SHA" && git checkout -q FETCH_HEAD
git apply "$PATCH"
mkdir build && cd build
../configure --target-list=e2k-linux-user --prefix="$PREFIX" \
    --disable-docs --disable-werror --disable-tools --disable-guest-agent > configure.log
ninja -j"$JOBS" > ninja.log
install -m 755 qemu-e2k "$PREFIX/bin/qemu-e2k"
rm -rf "$WORK"
echo "toolchain installed to $PREFIX"
