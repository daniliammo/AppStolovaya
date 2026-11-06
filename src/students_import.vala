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
// Совпадающие ФИО в разных группах требуют выбора актуальной группы
// или подтверждения, что это разные люди, до записи спорных строк.
// О карточке импорт знает только серию и номер: тип и код запишутся,
// когда её впервые приложат (Database.remember_card).

public class ImportResult {
    public int added;  // новые ученики
    public int updated;  // поменялись ФИО, группа или карточка
    public int unchanged;  // уже были в базе такими же
    public GenericArray<string> problems = new GenericArray<string> ();  // что не загружено: «Строка 5: …»
}

public class ImportGroupConflict {
    public string key;
    public string full_name;
    private string[] group_values = {};
    private string[] detail_values = {};
    public unowned string[] groups { get { return group_values; } }
    public unowned string[] details { get { return detail_values; } }

    public void add_group (string group, string detail) {
        var found = false;
        foreach (var existing in groups) {
            if (StudentsImport.name_key (existing) == StudentsImport.name_key (group)) {
                found = true;
                break;
            }
        }
        if (!found) {
            group_values += group;
        }
        detail_values += detail;
    }
}

namespace StudentsImport {
    // Регистр и случайные пробелы не должны скрывать возможный перевод.
    public string name_key (string name) {
        return string.joinv (" ", Regex.split_simple ("\\s+", name.strip ())).normalize ().casefold ();
    }

    public GenericArray<ImportGroupConflict> find_group_conflicts (Database database,
            GenericArray<SheetRow> rows) throws DatabaseError {
        var names = new HashTable<string, ImportGroupConflict> (str_hash, str_equal);
        var ordered = new GenericArray<ImportGroupConflict> ();
        foreach (var row in rows) {
            string name, group;
            int64 card;
            if (!parse_row (row.cells, out name, out group, out card)) {
                continue;
            }
            var key = name_key (name);
            var candidate = names[key];
            if (candidate == null) {
                candidate = new ImportGroupConflict () { key = key, full_name = name };
                names[key] = candidate;
                ordered.add (candidate);
            }
            candidate.add_group (group,
                @"Строка $(row.number): $group · карточка $(CardRead.format_uid (card))");
        }
        foreach (var student in database.list_students ()) {
            var candidate = names[name_key (student.full_name)];
            if (candidate != null) {
                candidate.add_group (student.group_name, @"В базе: $(student.group_name)");
            }
        }
        var conflicts = new GenericArray<ImportGroupConflict> ();
        foreach (var candidate in ordered) {
            if (candidate.groups.length > 1) {
                conflicts.add (candidate);
            }
        }
        return conflicts;
    }

    public ImportResult import_file (Database database, string path) throws Error {
        return import_rows (database, XlsxReader.read_first_sheet (path));
    }

    // Всё в одной транзакции: при ошибке базы не загружается ничего
    // choices: нормализованное ФИО → подтверждённая группа;
    // пустая строка означает подтверждение, что это разные люди.
    public ImportResult import_rows (Database database, GenericArray<SheetRow> rows,
            HashTable<string, string>? choices = null) throws DatabaseError {
        var result = new ImportResult ();
        var conflicts = new HashTable<string, ImportGroupConflict> (str_hash, str_equal);
        foreach (var conflict in find_group_conflicts (database, rows)) {
            conflicts[conflict.key] = conflict;
        }
        var resolved = new HashTable<string, bool> (str_hash, str_equal);
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

                var key = name_key (full_name);
                var transfer = false;
                if (conflicts.contains (key)) {
                    var choice = choices != null ? choices[key] : null;
                    if (choice == null) {
                        result.problems.add (@"Строка $(row.number): $full_name указан в разных группах. Скорее всего, ученик перевёлся — укажите актуальную группу.");
                        continue;
                    }
                    if (choice != "") {
                        if (name_key (choice) != name_key (group_name)) {
                            result.problems.add (@"Строка $(row.number): $full_name — выбрана актуальная группа $choice вместо $group_name");
                            continue;
                        }
                        if (resolved.contains (key)) {
                            result.problems.add (@"Строка $(row.number): повторная запись $full_name в выбранной группе $choice");
                            continue;
                        }
                        transfer = true;
                    }
                }
                var card = CardRead.format_uid (uid);
                if (seen.contains (card)) {
                    result.problems.add (@"Строка $(row.number): карточка $card уже была в строке $(seen[card])");
                    continue;
                }
                seen[card] = row.number;
                import_student (database, result, full_name, group_name, uid, transfer);
                if (transfer) {
                    resolved[key] = true;
                }
            }
        });
        return result;
    }

    private void import_student (Database database, ImportResult result,
                                 string full_name, string group_name, int64 uid,
                                 bool transfer = false) throws DatabaseError {
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
        if (student == null && transfer) {
            // После подтверждения перевода сохраняем ученика, его льготы и
            // историю даже при одновременной замене карточки.
            foreach (var existing in database.list_students ()) {
                if (name_key (existing.full_name) == name_key (full_name)) {
                    if (student != null) {
                        result.problems.add (@"$full_name: в базе несколько записей с этим ФИО. Уточните их в списке учеников перед повторным импортом.");
                        return;
                    }
                    student = existing;
                }
            }
        }
        if (student != null) {
            student.full_name = full_name;
            student.group_name = group_name;
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
