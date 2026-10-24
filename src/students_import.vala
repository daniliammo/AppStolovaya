// Импорт учеников из таблицы Excel. В строке — ФИО, группа и карточка
// (серия,номер — как напечатано на карточке):
//   Ворожцова Анжелика Николаевна | ПК12КР26 | 182,31128
// ФИО может занимать и три столбца, а вся строка — одну ячейку через пробелы:
// карточка — последнее, группа — перед ней, остальное — ФИО. Столбец
// с порядковым номером в начале пропускается.
//
// Ученик узнаётся по карточке: если она уже у кого-то, ему обновляются
// ФИО и группа (перевели в другую группу). Иначе карточку получает ученик
// с теми же ФИО и группой, а если такого нет — добавляется новый.
// О карточке импорт знает только серию и номер: тип и код запишутся,
// когда её впервые приложат (Database.remember_card).

public class ImportResult {
    public int added;  // новые ученики
    public int updated;  // поменялись ФИО, группа или карточка
    public int unchanged;  // уже были в базе такими же
    public GenericArray<string> problems = new GenericArray<string> ();  // что не загружено: «Строка 5: …»
}

namespace StudentsImport {
    public ImportResult import_file (Database database, string path) throws Error {
        return import_rows (database, XlsxReader.read_first_sheet (path));
    }

    // Всё в одной транзакции: при ошибке базы не загружается ничего
    public ImportResult import_rows (Database database, GenericArray<SheetRow> rows) throws DatabaseError {
        var result = new ImportResult ();
        var seen = new HashTable<string, int> (str_hash, str_equal);  // карточка → строка, где она была
        var header = true;  // первая непустая строка может быть заголовком таблицы
        database.transaction (() => {
            foreach (var row in rows) {
                string full_name, group_name;
                int64 uid;
                if (!parse_row (row.cells, out full_name, out group_name, out uid)) {
                    if (string.joinv ("", row.cells).strip () == "") {
                        continue;
                    }
                    if (!header) {
                        result.problems.add (@"Строка $(row.number): не похоже на «ФИО, группа, серия,номер карточки»");
                    }
                    header = false;
                    continue;
                }
                header = false;

                var card = CardRead.format_uid (uid);
                if (seen.contains (card)) {
                    result.problems.add (@"Строка $(row.number): карточка $card уже была в строке $(seen[card])");
                    continue;
                }
                seen[card] = row.number;
                import_student (database, result, full_name, group_name, uid);
            }
        });
        return result;
    }

    private void import_student (Database database, ImportResult result,
                                 string full_name, string group_name, int64 uid) throws DatabaseError {
        var owner = database.find_student_by_card (uid);
        if (owner != null) {
            if (owner.full_name == full_name && owner.group_name == group_name) {
                result.unchanged++;
                return;
            }
            owner.full_name = full_name;
            owner.group_name = group_name;
            database.update_student (owner);
            result.updated++;
            return;
        }

        var student = database.find_student_by_name (full_name, group_name);
        if (student != null) {
            student.card_uid = uid;  // новая карточка вместо прежней
            database.update_student (student);
            result.updated++;
        } else {
            database.add_student (full_name, group_name, uid);
            result.added++;
        }
    }

    // ФИО, группа и номер карточки из ячеек строки; false — строка не такая
    public bool parse_row (string[] cells, out string full_name, out string group_name, out int64 card_uid) {
        full_name = "";
        group_name = "";
        card_uid = 0;
        string[] parts = {};
        foreach (var cell in cells) {
            if (cell.strip () != "") {
                parts += cell.strip ();
            }
        }
        // Меньше трёх ячеек — значит, всё записано в одной-двух через пробелы
        if (parts.length < 3) {
            parts = Regex.split_simple ("\\s+", string.joinv (" ", parts).strip ());
        }
        // Порядковый номер в первом столбце («1» или «1.»)
        if (parts.length > 3 && Regex.match_simple ("^\\d+\\.?$", parts[0])) {
            parts = parts[1:parts.length];
        }

        var n = parts.length;
        if (n < 3 || !parse_card (parts[n - 1], out card_uid)) {
            return false;
        }
        group_name = parts[n - 2];
        string[] name_parts = parts[0:n - 2];
        full_name = string.joinv (" ", Regex.split_simple ("\\s+", string.joinv (" ", name_parts)));
        return true;
    }

    // Номер карточки из «182,31128» — как напечатано на карточке. Excel мог
    // сохранить его числом 182.31128, а у числа пропадают нули в конце
    // (120,09880 → 120.0988), поэтому дробная часть числа — это пять цифр.
    public bool parse_card (string text, out int64 card_uid) {
        card_uid = 0;
        MatchInfo match;
        if (!/^(\d{1,3})([,.])(\d+)$/.match (text, 0, out match)) {
            return false;
        }
        var series = int.parse (match.fetch (1));
        var digits = match.fetch (3);
        int number;
        if (match.fetch (2) == ",") {
            if (digits.length > 5) {
                return false;
            }
            number = int.parse (digits);
        } else {
            number = (int) (double.parse (@"0.$digits") * 100000 + 0.5);
        }
        if (series > 255 || number > 65535) {
            return false;
        }
        card_uid = (int64) series * 65536 + number;
        return true;
    }
}
