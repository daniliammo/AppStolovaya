#!/bin/sh
# Переносимая сборка (-Dportable=true): положить рядом с программой
# libadwaita и libxlsxwriter вместе с теми их зависимостями, которых нет
# среди зависимостей GTK. GTK и всё, на чём он стоит (glib, pango, cairo...),
# берётся из системы. Запускается из meson install.
#
#   bundle-libs.sh ПРОГРАММА
#
# ПРОГРАММА — собранный исполняемый файл, по нему ldd находит библиотеки.
# Программа ищет их рядом с собой через RPATH $ORIGIN (см. meson.build).
set -eu

exe=$1
dir=${MESON_INSTALL_DESTDIR_PREFIX:?запускается из meson install}

# Библиотеки, которые ld.so нашёл для файлов: «имя путь» на строку
libs () {
  ldd "$@" | awk '$2 == "=>" && $3 ~ /^\// { print $1, $3 }' | LC_ALL=C sort -u
}

# Путь к библиотеке программы по началу имени
lib_path () {
  libs "$exe" | awk -v name="$1" 'index($1, name) == 1 { print $2; exit }'
}

adwaita=$(lib_path libadwaita-1.so)
xlsxwriter=$(lib_path libxlsxwriter.so)
gtk=$(lib_path libgtk-4.so)
for lib in "$adwaita" "$xlsxwriter" "$gtk"; do
  [ -n "$lib" ] || { echo "bundle-libs: ldd не нашёл библиотеку" >&2; exit 1; }
done

system=$(mktemp)
trap 'rm -f "$system"' EXIT
# Из системы: GTK со всеми зависимостями и glibc
{
  libs "$gtk" | cut -d' ' -f1
  basename "$gtk"
  printf '%s\n' libc.so.6 libm.so.6 libpthread.so.0 libdl.so.2 librt.so.1 \
    libresolv.so.2
} | LC_ALL=C sort -u > "$system"

{
  echo "$(basename "$adwaita") $adwaita"
  echo "$(basename "$xlsxwriter") $xlsxwriter"
  libs "$adwaita" "$xlsxwriter"
} | LC_ALL=C sort -u | while read -r name path; do
  case $name in ld-linux*) continue ;; esac
  grep -qxF "$name" "$system" && continue
  cp -L "$path" "$dir/$name"
  chmod 644 "$dir/$name"
  echo "Пакет: $name"
done
