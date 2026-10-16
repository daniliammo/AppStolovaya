// Считыватель карт EM-Marine (125 кГц) и Mifare (13,56 МГц) на USB-переходнике FTDI.
// Порт 9600 бод, 8N1, текстовые строки:
//   при прикладывании — «Em-Marine[5500] 120,09886» (код в скобках, серия,номер),
//   у Mifare после номера хвост: «Mifare[658E6180045D85] 004,23941 UL (0144,00)»;
//   когда карточку убрали — «No card».
// Номер карточки в базе: серия × 65536 + номер (как в формате EM-Marine 8+16 бит).

// Одно считывание карточки
public class CardRead {
    public string raw;        // строка от считывателя как есть
    public string card_type;  // «Em-Marine» или «Mifare»
    public string code;       // число в квадратных скобках (hex)
    public int series;        // серия, 0–255
    public int number;        // номер, 0–65535

    // Номер карточки для базы
    public int64 uid {
        get { return (int64) series * 65536 + number; }
    }

    // Разобрать строку считывателя. null — это не строка с карточкой.
    public static CardRead? parse (string line) {
        MatchInfo match;
        if (!/^([A-Za-z-]+)\[([0-9A-Fa-f]+)\]\s+(\d{1,3}),(\d{1,5})(?:\s+.*)?$/.match (line.strip (), 0, out match)) {
            return null;
        }
        var series = int.parse (match.fetch (3));
        var number = int.parse (match.fetch (4));
        if (series > 255 || number > 65535) {
            return null;
        }
        return new CardRead () {
            raw = line.strip (),
            card_type = match.fetch (1),
            code = match.fetch (2),
            series = series,
            number = number
        };
    }
}

public enum ReaderState {
    DISCONNECTED,  // считыватель не подключён
    NO_ACCESS,     // подключён, но нет прав на порт (нужна настройка системы)
    CONNECTED
}

public class CardReader : Object {
    public ReaderState state { get; private set; default = ReaderState.DISCONNECTED; }
    public string? device_path { get; private set; }

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
        if (!open_port (path)) {
            change_state (Posix.errno == Posix.EACCES ? ReaderState.NO_ACCESS : ReaderState.DISCONNECTED, path);
            return;
        }
        change_state (ReaderState.CONNECTED, path);
    }

    private void change_state (ReaderState new_state, string? path) {
        if (state != new_state || device_path != path) {
            device_path = path;
            state = new_state;
        }
    }

    private bool open_port (string path) {
        var new_fd = Posix.open (path, Posix.O_RDWR | Posix.O_NOCTTY | Posix.O_NONBLOCK);
        if (new_fd < 0) {
            return false;
        }

        Posix.termios tio;
        if (Posix.tcgetattr (new_fd, out tio) != 0) {
            Posix.close (new_fd);
            return false;
        }
        Posix.cfmakeraw (ref tio);
        Posix.cfsetispeed (ref tio, Posix.B9600);
        Posix.cfsetospeed (ref tio, Posix.B9600);
        tio.c_cflag |= Posix.CLOCAL | Posix.CREAD;
        if (Posix.tcsetattr (new_fd, Posix.TCSANOW, tio) != 0) {
            Posix.close (new_fd);
            return false;
        }
        Posix.tcflush (new_fd, Posix.TCIOFLUSH);

        fd = new_fd;
        line.truncate ();
        card_present = false;
        channel = new IOChannel.unix_new (fd);
        watch_id = channel.add_watch (IOCondition.IN | IOCondition.HUP | IOCondition.ERR | IOCondition.NVAL, on_data);
        return true;
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
