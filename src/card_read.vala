// Считыватель карт EM-Marine (125 кГц) и Mifare (13,56 МГц) на USB-переходнике FTDI.
// Порт 9600 бод, 8N1, текстовые строки:
//   при прикладывании — «Em-Marine[5500] 120,09886» (код в скобках, серия,номер),
//   у Mifare после номера хвост: «Mifare[658E6180045D85] 004,23941 UL (0144,00)»;
//   когда карточку убрали — «No card».
// Номер карточки в базе: серия × 65536 + номер (как в формате EM-Marine 8+16 бит).

// Одно считывание карточки
public class CardRead {
    // Тип карточки, приложенной в тестовом режиме
    public const string TEST_TYPE = "Тест";

    public string raw;        // строка от считывателя как есть
    public string card_type;  // «Em-Marine», «Mifare» или «Тест» (тестовый режим)
    public string code;       // число в квадратных скобках (hex)
    public int series;        // серия, 0–255
    public int number;        // номер, 0–65535
    public string? scanned_at;  // 'HH:MM:SS' — у карточек, прочитанных из базы

    // Номер карточки для базы
    public int64 uid {
        get { return (int64) series * 65536 + number; }
    }

    // Номер для базы так, как его печатают на карточке: «120,09886»
    public static string format_uid (int64 uid) {
        return "%s,%05d".printf ((uid / 65536).to_string (), (int) (uid % 65536));
    }

    // Разобрать строку считывателя. null — это не строка с карточкой.
    public static CardRead? parse (string line) {
        // match хранит указатель на строку, а не копию: строка должна жить,
        // пока из match достают группы
        var text = line.strip ();
        MatchInfo match;
        print (@"$line\n");
        if (!/^([A-Za-z-]+)\[([0-9A-Fa-f]+)\]\s+(\d{1,3}),(\d{1,5})(?:\s+.*)?$/.match (text, 0, out match)) {
            return null;
        }
        var series = int.parse (match.fetch (3));
        var number = int.parse (match.fetch (4));
        if (series > 255 || number > 65535) {
            return null;
        }
        return new CardRead () {
            raw = text,
            card_type = match.fetch (1),
            code = match.fetch (2),
            series = series,
            number = number
        };
    }
}
