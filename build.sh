#!/bin/sh
# Сборка программы.
#
#   ./build.sh                    отладочная сборка в build/
#   ./build.sh --release          сборка для выдачи в build-release/
#   ./build.sh --package          переносимая сборка для выдачи: папка
#                                 dist/Столовая/ с программой и .so libadwaita
#                                 и libxlsxwriter рядом с ней (сборка в build-package/)
#   ./build.sh --package --debug  то же, но отладочная: dist/Столовая-debug/
#                                 (сборка в build-package-debug/)
set -eu

cd "$(dirname "$0")"
src=$(pwd)

release=false
debug=false
package=false
for arg in "$@"; do
  case "$arg" in
    --release) release=true ;;
    --debug) debug=true ;;
    --package) package=true ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Неизвестный флаг: $arg" >&2; exit 2 ;;
  esac
done

if $release && $debug; then
  echo "--release и --debug нельзя указать вместе" >&2
  exit 2
fi

dir=build
buildtype=debug
$release && buildtype=release
if $package; then
  # Пакет по умолчанию для выдачи; --debug — отладочный пакет отдельно
  dir=$dir-package
  out=dist/Столовая
  if $debug; then
    dir=$dir-debug
    out=$out-debug
  else
    buildtype=release
  fi
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
