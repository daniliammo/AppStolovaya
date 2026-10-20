#!/bin/sh
# Сборка программы.
#
#   ./build.sh              отладочная сборка в build/
#   ./build.sh --release    сборка для выдачи в build-release/
#   ./build.sh --package    переносимая сборка для выдачи: папка
#                           dist/Столовая/ с программой и .so libadwaita
#                           и libxlsxwriter рядом с ней (сборка в build-package/)
set -eu

cd "$(dirname "$0")"
src=$(pwd)

release=false
package=false
for arg in "$@"; do
  case "$arg" in
    --release) release=true ;;
    --package) package=true ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Неизвестный флаг: $arg" >&2; exit 2 ;;
  esac
done

dir=build
buildtype=debug
$release && buildtype=release
if $package; then
  # Пакет всегда для выдачи: без тестовых частей
  dir=$dir-package
  buildtype=release
  out=dist/Столовая
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

[ -f "$dir/build.ninja" ] || eval meson setup "'$dir'" --buildtype="$buildtype" $setup_args
eval "$build"
