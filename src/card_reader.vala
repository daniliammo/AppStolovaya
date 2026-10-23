// Считыватель карт на USB-переходнике FTDI; формат строк — в card_read.vala

public class CardReader : Object {
    public ReaderState state { get; private set; default = ReaderState.DISCONNECTED; }
    public string? device_path { get; private set; }
    // Почему порт не открылся (errno) — для состояния UNAVAILABLE
    public int open_error { get; private set; }

    // Приложили карточку: одно событие на прикладывание (до «No card»)
    public signal void card_read (CardRead card);

    private int fd = -1;
    private IOChannel? channel;
    private uint watch_id = 0;
    private StringBuilder line = new StringBuilder ();
    private bool card_present = false;
    private int64 present_uid = -1;

    // Подключение проверяется раз в секунду, отключение замечается сразу
    // по закрытию порта
    public void start () {
        check_connection ();
        Timeout.add_seconds (1, () => {
            check_connection ();
            return Source.CONTINUE;
        });
    }

    private void check_connection () {
        if (fd >= 0) {
            return;
        }
        var path = SystemSetup.find_reader ();
        if (path == null) {
            change_state (ReaderState.DISCONNECTED, null);
            return;
        }
        var error = open_port (path);
        switch (error) {
            case 0:
                change_state (ReaderState.CONNECTED, path);
                break;
            case Posix.EACCES:
                change_state (ReaderState.NO_ACCESS, path);
                break;
            case Posix.ENOENT:
            case Posix.ENODEV:
            case Posix.ENXIO:
                // Устройство пропало между поиском и открытием
                change_state (ReaderState.DISCONNECTED, null);
                break;
            default:
                // Есть, но не открывается: например, порт занят ModemManager
                change_state (ReaderState.UNAVAILABLE, path, error);
                break;
        }
    }

    private void change_state (ReaderState new_state, string? path, int error = 0) {
        if (state == new_state && device_path == path && open_error == error) {
            return;
        }
        device_path = path;
        open_error = error;
        if (state != new_state) {
            state = new_state;
        } else {
            notify_property ("state");  // то же состояние, но другая ошибка
        }
    }

    // Открыть и настроить порт. Возвращает 0 или errno.
    private int open_port (string path) {
        var new_fd = Posix.open (path, Posix.O_RDWR | Posix.O_NOCTTY | Posix.O_NONBLOCK);
        if (new_fd < 0) {
            return Posix.errno;
        }

        // errno запоминаем до close (): он может его затереть
        Posix.termios tio;
        if (Posix.tcgetattr (new_fd, out tio) != 0) {
            var error = Posix.errno;
            Posix.close (new_fd);
            return error;
        }
        Posix.cfmakeraw (ref tio);
        Posix.cfsetispeed (ref tio, Posix.B9600);
        Posix.cfsetospeed (ref tio, Posix.B9600);
        tio.c_cflag |= Posix.CLOCAL | Posix.CREAD;
        if (Posix.tcsetattr (new_fd, Posix.TCSANOW, tio) != 0) {
            var error = Posix.errno;
            Posix.close (new_fd);
            return error;
        }
        Posix.tcflush (new_fd, Posix.TCIOFLUSH);

        fd = new_fd;
        line.truncate ();
        card_present = false;
        channel = new IOChannel.unix_new (fd);
        watch_id = channel.add_watch (IOCondition.IN | IOCondition.HUP | IOCondition.ERR | IOCondition.NVAL, on_data);
        return 0;
    }

    private void close_port () {
        if (watch_id != 0) {
            Source.remove (watch_id);
            watch_id = 0;
        }
        channel = null;
        if (fd >= 0) {
            Posix.close (fd);
            fd = -1;
        }
    }

    private bool on_data (IOChannel source, IOCondition condition) {
        if (IOCondition.IN in condition) {
            uint8 buffer[256];
            var count = Posix.read (fd, buffer, buffer.length);
            if (count > 0) {
                for (int i = 0; i < count; i++) {
                    on_byte (buffer[i]);
                }
                return Source.CONTINUE;
            }
            if (count < 0 && Posix.errno == Posix.EAGAIN) {
                return Source.CONTINUE;
            }
        }

        // Ошибка или конец данных — считыватель отключили
        watch_id = 0;  // источник удалится сам, раз вернули REMOVE
        close_port ();
        change_state (ReaderState.DISCONNECTED, null);
        check_connection ();  // вдруг уже подключили снова
        return Source.REMOVE;
    }

    // Берём только печатные символы: сразу после открытия порта от
    // считывателя приходят нулевые байты («\0\0Em-Marine…»), а с ними
    // первая строка не разобралась бы
    private void on_byte (uint8 b) {
        if (b == '\n') {
            on_line (line.str);
            line.truncate ();
        } else if (b >= 0x20 && b < 0x7F && line.len < 256) {
            line.append_c ((char) b);
        }
    }

    // Повтор той же карточки, пока её не убрали, — одно прикладывание.
    // Другая карточка проходит, даже если «No card» потерялось.
    private void on_line (string text) {
        if (text.strip () == "No card") {
            card_present = false;
            return;
        }
        var card = CardRead.parse (text);
        if (card == null || (card_present && card.uid == present_uid)) {
            return;
        }
        card_present = true;
        present_uid = card.uid;
        card_read (card);
    }
}
