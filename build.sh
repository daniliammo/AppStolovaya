#!/bin/sh
# Сборка программы.
#
#   ./build.sh              отладочная сборка в build/
#   ./build.sh --release    сборка для выдачи в build-release/
#   ./build.sh --32         32-битная (i386) сборка в build32/
#   ./build.sh --32 --release   то же для выдачи, в build32-release/
#
# 32-битная сборка идёт в контейнере Docker (tools/i386.Dockerfile):
# нужен запущенный docker и права на него (группа docker или sudo).
set -eu

cd "$(dirname "$0")"
src=$(pwd)

arch32=false
release=false
for arg in "$@"; do
  case "$arg" in
    --32) arch32=true ;;
    --release) release=true ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Неизвестный флаг: $arg" >&2; exit 2 ;;
  esac
done

dir=build
$arch32 && dir=build32
$release && dir=$dir-release
buildtype=debug
$release && buildtype=release

if ! $arch32; then
  [ -f "$dir/build.ninja" ] || meson setup "$dir" --buildtype="$buildtype"
  exec meson compile -C "$dir"
fi

image=stolovaya-i386
docker build --network host -t "$image" -f tools/i386.Dockerfile tools

# Исходники монтируются по тому же пути, что и снаружи: пути к базе и
# к stolovaya-setup зашиты в config.vala при настройке meson.
# setarch i686 — чтобы uname внутри контейнера тоже сообщал 32 бита.
docker run --rm \
  --user "${SUDO_UID:-$(id -u)}:${SUDO_GID:-$(id -g)}" \
  -e HOME=/tmp \
  -v "$src:$src" \
  -w "$src" \
  "$image" \
  setarch i686 sh -ec "
    [ -f '$dir/build.ninja' ] || meson setup '$dir' --buildtype='$buildtype'
    meson compile -C '$dir'
  "
