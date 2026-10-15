// Настройка системы для программы «Столовая». Запускается от root через pkexec
// кнопкой «Настроить» в настройках программы. Повторный запуск безопасен.
//
// Что делает:
//   1. Правило udev для считывателя карт (USB-переходник FTDI FT232R, 0403:6001):
//      - доступ к порту пользователю, вошедшему в систему (uaccess), сразу,
//        без повторного входа;
//      - ModemManager не опрашивает этот порт (ID_MM_DEVICE_IGNORE);
//      - постоянное имя /dev/stolovaya-reader.
//   2. Добавляет пользователя в группу dialout: запасной способ доступа к порту,
//      начинает действовать после повторного входа в систему.
//
// Сеть не затрагивается: NetworkManager, ModemManager, VPN и их настройки
// не меняются и не перезапускаются, udev перечитывает только порты ttyUSB*.

const string RULES = "/etc/udev/rules.d/60-stolovaya-reader.rules";

const string RULES_TEXT = """# Программа «Столовая»: считыватель карт через USB-переходник FTDI FT232R.
# Доступ пользователю за компьютером, ModemManager порт не трогает.
SUBSYSTEM=="tty", ATTRS{idVendor}=="0403", ATTRS{idProduct}=="6001", TAG+="uaccess", ENV{ID_MM_DEVICE_IGNORE}="1", SYMLINK+="stolovaya-reader"
""";

// Запустить команду; при ненулевом коде — ошибка, если не разрешено иное
void run_command (string[] argv, bool may_fail = false) throws Error {
    int status;
    Process.spawn_sync (null, argv, null, SpawnFlags.SEARCH_PATH, null, null, null, out status);
    if (!may_fail) {
        Process.check_wait_status (status);
    }
}

// pkexec передаёт uid пользователя, который запустил программу
string? invoking_user () {
    var uid_text = Environment.get_variable ("PKEXEC_UID");
    uint64 uid = 0;
    if (uid_text == null || !uint64.try_parse (uid_text, out uid)) {
        return null;
    }
    unowned Posix.Passwd? pw = Posix.getpwuid ((Posix.uid_t) uid);
    return pw != null ? pw.pw_name : null;
}

bool in_group (string user, string group_name) {
    unowned Posix.Group? gr = Posix.getgrnam (group_name);
    if (gr == null) {
        return false;
    }
    foreach (unowned string member in gr.gr_mem) {
        if (member == user) {
            return true;
        }
    }
    // Основная группа пользователя в списке членов не перечисляется
    unowned Posix.Passwd? pw = Posix.getpwnam (user);
    return pw != null && pw.pw_gid == gr.gr_gid;
}

int main () {
    if (Posix.getuid () != 0) {
        printerr ("Нужны права администратора: запускайте через pkexec\n");
        return 1;
    }
    var user = invoking_user ();
    if (user == null) {
        printerr ("Не удалось определить пользователя\n");
        return 1;
    }

    try {
        // 1. Правило udev (во временный файл, затем замена одной операцией)
        var tmp = RULES + ".tmp";
        FileUtils.set_contents (tmp, RULES_TEXT);
        FileUtils.chmod (tmp, 0644);
        if (FileUtils.rename (tmp, RULES) != 0) {
            throw new FileError.FAILED ("Не удалось записать %s: %s", RULES, strerror (errno));
        }
        print ("Правило udev: %s\n", RULES);

        // 2. Группа dialout
        if (in_group (user, "dialout")) {
            print ("Пользователь %s уже в группе dialout\n", user);
        } else {
            run_command ({ "usermod", "-aG", "dialout", user });
            print ("Пользователь %s добавлен в группу dialout\n", user);
        }

        // Применить правило к уже подключённым переходникам, не трогая остальные устройства
        run_command ({ "udevadm", "control", "--reload-rules" });
        run_command ({ "udevadm", "trigger", "--action=change",
                       "--subsystem-match=tty", "--sysname-match=ttyUSB*" });
        run_command ({ "udevadm", "settle", "--timeout=10" }, true);
    } catch (Error e) {
        printerr ("%s\n", e.message);
        return 1;
    }
    print ("Готово\n");
    return 0;
}
