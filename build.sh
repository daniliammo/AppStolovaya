#!/bin/sh
# Сборка программы.
#
#   ./build.sh              отладочная сборка в build/
#   ./build.sh --release    сборка для выдачи в build-release/
#   ./build.sh --32         32-битная (i386) сборка в build32/
#   ./build.sh --32 --release   то же для выдачи, в build32-release/
#   ./build.sh --package    переносимая сборка для выдачи: папка
#                           dist/Столовая/ с программой и .so libadwaita
#                           и libxlsxwriter рядом с ней (сборка в build-package/)
#   ./build.sh --32 --package   то же для 32 бит, в dist/Столовая-32/
#
# 32-битная сборка идёт в контейнере Docker (tools/i386.Dockerfile):
# нужен запущенный docker и права на него (группа docker или sudo).
set -eu

cd "$(dirname "$0")"
src=$(pwd)

arch32=false
release=false
package=false
for arg in "$@"; do
  case "$arg" in
    --32) arch32=true ;;
    --release) release=true ;;
    --package) package=true ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Неизвестный флаг: $arg" >&2; exit 2 ;;
  esac
done

dir=build
$arch32 && dir=build32
buildtype=debug
$release && buildtype=release
if $package; then
  # Пакет всегда для выдачи: без тестовых частей
  dir=$dir-package
  buildtype=release
  out=dist/Столовая
  $arch32 && out=$out-32
else
  $release && dir=$dir-release
fi

setup_args=
build="meson compile -C '$dir'"
if $package; then
  # meson install кладёт программу и .so в папку пакета (prefix);
  # старая папка удаляется, чтобы не осталось лишних библиотек
  setup_args="-Dportable=true --prefix='$src/$out'"
  build="rm -rf '$out' && meson install -C '$dir' --quiet"
fi
script="
  [ -f '$dir/build.ninja' ] || meson setup '$dir' --buildtype='$buildtype' $setup_args
  $build
"

if ! $arch32; then
  exec sh -ec "$script"
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
  setarch i686 sh -ec "$script"
