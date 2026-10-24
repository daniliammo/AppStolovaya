// Тесты импорта учеников из Excel. Запуск: meson test -C build

int64 uid (int series, int number) {
    return (int64) series * 65536 + number;
}

void test_parse_card () {
    int64 card;
    assert_true (StudentsImport.parse_card ("182,31128", out card) && card == uid (182, 31128));
    assert_true (StudentsImport.parse_card ("120,09886", out card) && card == uid (120, 9886));
    assert_true (StudentsImport.parse_card ("3,513", out card) && card == uid (3, 513));
    // Числом Excel: нули в конце пропали, лишние знаки — от двоичной дроби
    assert_true (StudentsImport.parse_card ("120.0988", out card) && card == uid (120, 9880));
    assert_true (StudentsImport.parse_card ("182.31127999999999", out card) && card == uid (182, 31128));
    assert_false (StudentsImport.parse_card ("256,00001", out card));
    assert_false (StudentsImport.parse_card ("1,99999", out card));
    assert_false (StudentsImport.parse_card ("1,123456", out card));
    assert_false (StudentsImport.parse_card ("Карточка", out card));
    assert_false (StudentsImport.parse_card ("", out card));
}

void assert_row (string[] cells, string full_name, string group_name, int64 card_uid) {
    string name, group;
    int64 card;
    assert_true (StudentsImport.parse_row (cells, out name, out group, out card));
    assert_cmpstr (name, CompareOperator.EQ, full_name);
    assert_cmpstr (group, CompareOperator.EQ, group_name);
    assert_true (card == card_uid);
}

void test_parse_row () {
    var card = uid (182, 31128);
    assert_row ({ "Ворожцова Анжелика Николаевна", "ПК12КР26", "182,31128" },
        "Ворожцова Анжелика Николаевна", "ПК12КР26", card);
    // ФИО в трёх столбцах, пустые столбцы между ними, номер по порядку
    assert_row ({ "1", "Ворожцова", "Анжелика", "", "Николаевна", " ПК12КР26 ", "182,31128" },
        "Ворожцова Анжелика Николаевна", "ПК12КР26", card);
    // Всё в одной ячейке — как скопировано из таблицы
    assert_row ({ "Ворожцова Анжелика Николаевна\tПК12КР26\t182,31128" },
        "Ворожцова Анжелика Николаевна", "ПК12КР26", card);
    assert_row ({ "Ворожцова  Анжелика   Николаевна    ПК12КР26    182,31128" },
        "Ворожцова Анжелика Николаевна", "ПК12КР26", card);

    string name, group;
    int64 number;
    assert_false (StudentsImport.parse_row ({ "ФИО", "Группа", "Карточка" }, out name, out group, out number));
    assert_false (StudentsImport.parse_row ({ "Ворожцова Анжелика", "ПК12КР26" }, out name, out group, out number));
    assert_false (StudentsImport.parse_row ({ "ПК12КР26", "182,31128" }, out name, out group, out number));
    assert_false (StudentsImport.parse_row ({}, out name, out group, out number));
}

// Таблица, как её сохранил бы Excel: заголовок, пустая строка, карточка
// и строкой, и числом
string write_sample (string dir) {
    var path = Path.build_filename (dir, "ученики.xlsx");
    var workbook = Xlsx.Workbook.create (path);
    unowned var sheet = workbook.add_worksheet ("Ученики");
    sheet.write_string (0, 0, "ФИО");
    sheet.write_string (0, 1, "Группа");
    sheet.write_string (0, 2, "Карточка");
    sheet.write_string (1, 0, "Ворожцова Анжелика Николаевна");
    sheet.write_string (1, 1, "ПК12КР26");
    sheet.write_string (1, 2, "182,31128");
    sheet.write_string (3, 0, "Гуров Данил Дмитриевич");
    sheet.write_string (3, 1, "ИС21");
    sheet.write_number (3, 2, 120.09886);
    sheet.write_string (4, 0, "Без карточки");
    sheet.write_string (4, 1, "ИС21");
    sheet.write_string (5, 0, "Двойник");
    sheet.write_string (5, 1, "ИС21");
    sheet.write_string (5, 2, "182,31128");
    workbook.close ();
    return path;
}

void test_read_xlsx () throws Error {
    var dir = DirUtils.make_tmp ("stolovaya-test-XXXXXX");
    var path = write_sample (dir);

    var rows = XlsxReader.read_first_sheet (path);
    assert_cmpint (rows.length, CompareOperator.EQ, 5);  // пустую строку 3 Excel не хранит
    assert_cmpint (rows[0].number, CompareOperator.EQ, 1);
    assert_cmpstr (rows[0].cells[2], CompareOperator.EQ, "Карточка");
    assert_cmpstr (rows[1].cells[0], CompareOperator.EQ, "Ворожцова Анжелика Николаевна");
    assert_cmpint (rows[2].number, CompareOperator.EQ, 4);
    assert_cmpstr (rows[2].cells[2], CompareOperator.EQ, "120.09886");
    assert_cmpint (rows[3].cells.length, CompareOperator.EQ, 2);

    // Не .xlsx — понятная ошибка
    var text = Path.build_filename (dir, "список.xls");
    FileUtils.set_contents (text, "Ворожцова Анжелика Николаевна\tПК12КР26\t182,31128\n");
    try {
        XlsxReader.read_first_sheet (text);
        assert_not_reached ();
    } catch (XlsxError e) {
        assert_true ("«список.xls»" in e.message);
    }

    FileUtils.remove (path);
    FileUtils.remove (text);
    DirUtils.remove (dir);
}

void test_import () throws Error {
    var dir = DirUtils.make_tmp ("stolovaya-test-XXXXXX");
    var path = write_sample (dir);
    var db = new Database (":memory:");
    // Уже в базе без карточки — получит карточку, а не появится второй раз
    db.add_student ("Гуров Данил Дмитриевич", "ИС21");

    var result = StudentsImport.import_file (db, path);
    assert_cmpint (result.added, CompareOperator.EQ, 1);
    assert_cmpint (result.updated, CompareOperator.EQ, 1);
    assert_cmpint (result.unchanged, CompareOperator.EQ, 0);
    assert_cmpint (result.problems.length, CompareOperator.EQ, 2);
    assert_true (result.problems[0].has_prefix ("Строка 5:"));
    assert_true (result.problems[1].has_prefix ("Строка 6:") && "строке 2" in result.problems[1]);
    assert_cmpint (db.list_students ().length, CompareOperator.EQ, 2);

    // Карточка — только серия и номер, остальное допишет первое прикладывание
    var student = db.find_student_by_card (uid (182, 31128));
    assert_cmpstr (student.full_name, CompareOperator.EQ, "Ворожцова Анжелика Николаевна");
    assert_cmpstr (student.group_name, CompareOperator.EQ, "ПК12КР26");
    assert_cmpstr (db.find_card (uid (182, 31128)).card_type, CompareOperator.EQ, "");
    assert_cmpstr (db.find_student_by_card (uid (120, 9886)).full_name, CompareOperator.EQ, "Гуров Данил Дмитриевич");

    // Повторный импорт ничего не меняет
    result = StudentsImport.import_file (db, path);
    assert_cmpint (result.added, CompareOperator.EQ, 0);
    assert_cmpint (result.updated, CompareOperator.EQ, 0);
    assert_cmpint (result.unchanged, CompareOperator.EQ, 2);

    // Перевели в другую группу — ученик тот же, с той же карточкой
    var rows = new GenericArray<SheetRow> ();
    rows.add (new SheetRow () { number = 1, cells = { "Ворожцова Анжелика Николаевна", "ПК22КР26", "182,31128" } });
    result = StudentsImport.import_rows (db, rows);
    assert_cmpint (result.updated, CompareOperator.EQ, 1);
    assert_cmpint ((int) db.find_student_by_card (uid (182, 31128)).id, CompareOperator.EQ, (int) student.id);
    assert_cmpstr (db.find_student_by_card (uid (182, 31128)).group_name, CompareOperator.EQ, "ПК22КР26");

    FileUtils.remove (path);
    DirUtils.remove (dir);
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/students-import/parse-card", test_parse_card);
    Test.add_func ("/students-import/parse-row", test_parse_row);
    Test.add_func ("/students-import/read-xlsx", () => wrap (test_read_xlsx));
    Test.add_func ("/students-import/import", () => wrap (test_import));
    return Test.run ();
}

delegate void TestBody () throws Error;

// Любая неожиданная ошибка — провал теста с её текстом
void wrap (TestBody body) {
    try {
        body ();
    } catch (Error e) {
        error ("%s", e.message);
    }
}
