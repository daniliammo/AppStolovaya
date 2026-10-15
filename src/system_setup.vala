// Настройка системы под считыватель карт: проверка состояния и запуск
// stolovaya-setup (tools/setup_system.vala) от root через pkexec (GNOME сам спросит пароль).
// Что именно меняется в системе — см. комментарий в начале tools/setup_system.vala.

public errordomain SetupError {
    CANCELLED,  // окно пароля закрыли или пароль не подошёл
    FAILED
}

namespace SystemSetup {
    // Правило udev, которое ставит stolovaya-setup
    public const string RULES_FILE = "/etc/udev/rules.d/60-stolovaya-reader.rules";
    // Постоянное имя считывателя из этого правила
    public const string READER_LINK = "/dev/stolovaya-reader";

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
                FileAttribute.ACCESS_CAN_READ + "," + FileAttribute.ACCESS_CAN_WRITE,
                FileQueryInfoFlags.NONE);
            return info.get_attribute_boolean (FileAttribute.ACCESS_CAN_READ)
                && info.get_attribute_boolean (FileAttribute.ACCESS_CAN_WRITE);
        } catch (Error e) {
            return false;
        }
    }

    // Запустить программу настройки от root. Возвращает его вывод.
    public async string run () throws Error {
        var process = new Subprocess.newv (
            { "pkexec", Config.SETUP_PROGRAM },
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
}
