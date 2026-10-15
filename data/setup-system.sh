#!/bin/sh
# Настройка системы для программы «Столовая». Запускается от root через pkexec
# кнопкой «Настроить» в настройках программы. Повторный запуск безопасен.
#
# Что делает:
#   1. Правило udev для считывателя карт (USB-переходник FTDI FT232R, 0403:6001):
#      - доступ к порту пользователю, вошедшему в систему (uaccess), сразу,
#        без повторного входа;
#      - ModemManager не опрашивает этот порт (ID_MM_DEVICE_IGNORE);
#      - постоянное имя /dev/stolovaya-reader.
#   2. Добавляет пользователя в группу dialout: запасной способ доступа к порту,
#      начинает действовать после повторного входа в систему.
#
# Сеть не затрагивается: NetworkManager, ModemManager, VPN и их настройки
# не меняются и не перезапускаются, udev перечитывает только порты ttyUSB*.

set -eu

RULES=/etc/udev/rules.d/60-stolovaya-reader.rules

if [ "$(id -u)" -ne 0 ]; then
    echo "Нужны права администратора: запускайте через pkexec" >&2
    exit 1
fi

# pkexec передаёт uid пользователя, который запустил программу
user=""
if [ -n "${PKEXEC_UID:-}" ]; then
    user=$(getent passwd "$PKEXEC_UID" | cut -d: -f1)
fi
if [ -z "$user" ]; then
    echo "Не удалось определить пользователя" >&2
    exit 1
fi

# 1. Правило udev (во временный файл, затем замена одной операцией)
cat > "$RULES.tmp" <<'EOF'
# Программа «Столовая»: считыватель карт через USB-переходник FTDI FT232R.
# Доступ пользователю за компьютером, ModemManager порт не трогает.
SUBSYSTEM=="tty", ATTRS{idVendor}=="0403", ATTRS{idProduct}=="6001", TAG+="uaccess", ENV{ID_MM_DEVICE_IGNORE}="1", SYMLINK+="stolovaya-reader"
EOF
chmod 644 "$RULES.tmp"
mv "$RULES.tmp" "$RULES"
echo "Правило udev: $RULES"

# 2. Группа dialout
if id -nG "$user" | tr ' ' '\n' | grep -qx dialout; then
    echo "Пользователь $user уже в группе dialout"
else
    usermod -aG dialout "$user"
    echo "Пользователь $user добавлен в группу dialout"
fi

# Применить правило к уже подключённым переходникам, не трогая остальные устройства
udevadm control --reload-rules
udevadm trigger --action=change --subsystem-match=tty --sysname-match='ttyUSB*'
udevadm settle --timeout=10 || true
echo "Готово"
