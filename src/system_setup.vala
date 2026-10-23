// Настройка системы под считыватель карт. Программа запускает сама себя
// с флагом --setup-system от root через pkexec (GNOME сам спросит пароль):
// окно не открывается, настройка выполняется, и программа завершается.
// Повторный запуск безопасен.
//
// Что делает настройка (apply):
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

public errordomain SetupError {
    CANCELLED,  // окно пароля закрыли или пароль не подошёл
    FAILED
}

namespace SystemSetup {
    // Флаг командной строки: выполнить настройку вместо запуска программы
    public const string FLAG = "--setup-system";

    // Правило udev, которое ставит настройка
    public const string RULES_FILE = "/etc/udev/rules.d/60-stolovaya-reader.rules";
    // Постоянное имя считывателя из этого правила
    public const string READER_LINK = "/dev/stolovaya-reader";

    const string RULES_TEXT = """# Программа «Столовая»: считыватель карт через USB-переходник FTDI FT232R.
# Доступ пользователю за компьютером, ModemManager порт не трогает.
SUBSYSTEM=="tty", ATTRS{idVendor}=="0403", ATTRS{idProduct}=="6001", TAG+="uaccess", ENV{ID_MM_DEVICE_IGNORE}="1", SYMLINK+="stolovaya-reader"
""";

    public bool rules_installed () {
        return FileUtils.test (RULES_FILE, FileTest.EXISTS);
    }

    // Путь к считывателю или null, если он не подключён. До настройки
    // постоянного имени нет — ищем переходник FTDI в /dev/serial/by-id.
    public string? find_reader () {
        if (FileUtils.test (READER_LINK, FileTest.EXISTS)) {
            return READER_LINK;
        }
        try {
            var dir = Dir.open ("/dev/serial/by-id");
            string? name;
            while ((name = dir.read_name ()) != null) {
                if (name.has_prefix ("usb-FTDI_")) {
                    return Path.build_filename ("/dev/serial/by-id", name);
                }
            }
        } catch (FileError e) {
            // Папки нет — ни одного последовательного USB-устройства
        }
        return null;
    }

    // Может ли программа читать порт и писать в него
    public bool can_access (string path) {
        try {
            var info = File.new_for_path (path).query_info (
                @"$(FileAttribute.ACCESS_CAN_READ),$(FileAttribute.ACCESS_CAN_WRITE)",
                FileQueryInfoFlags.NONE);
            return info.get_attribute_boolean (FileAttribute.ACCESS_CAN_READ)
                && info.get_attribute_boolean (FileAttribute.ACCESS_CAN_WRITE);
        } catch (Error e) {
            return false;
        }
    }

    // Запустить эту же программу с флагом настройки от root. Возвращает её вывод.
    public async string run () throws Error {
        var program = FileUtils.read_link ("/proc/self/exe");
        var process = new Subprocess.newv (
            { "pkexec", program, FLAG },
            SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_MERGE);
        string output;
        yield process.communicate_utf8_async (null, null, out output, null);
        output = (output ?? "").strip ();

        if (!process.get_if_exited ()) {
            throw new SetupError.FAILED ("Настройка прервана");
        }
        switch (process.get_exit_status ()) {
        case 0:
            return output;
        case 126:
        case 127:
            // Коды pkexec: окно закрыто, пароль неверный или нет прав администратора
            throw new SetupError.CANCELLED ("Настройка отменена: нужен пароль администратора");
        default:
            throw new SetupError.FAILED ("%s", output != "" ? output : "Настройка завершилась с ошибкой");
        }
    }

    // --- Настройка от root (программа запущена с флагом FLAG) ---

    // Выполнить настройку. Возвращает код завершения программы.
    public int apply () {
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
            var tmp = @"$RULES_FILE.tmp";
            FileUtils.set_contents (tmp, RULES_TEXT);
            FileUtils.chmod (tmp, 0644);
            if (FileUtils.rename (tmp, RULES_FILE) != 0) {
                throw new FileError.FAILED ("Не удалось записать %s: %s", RULES_FILE, strerror (errno));
            }
            print ("Правило udev: %s\n", RULES_FILE);

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
}
