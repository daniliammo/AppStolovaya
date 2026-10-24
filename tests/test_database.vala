// Тесты базы данных. Запуск: meson test -C build

DateTime at (int day, int hour, int minute) {
    return new DateTime.local (2026, 10, day, hour, minute, 0);
}

void test_schema () throws Error {
    var db = new Database (":memory:");
    assert_cmpint (db.schema_version (), CompareOperator.EQ, 6);
}

void test_students () throws Error {
    var db = new Database (":memory:");
    var id = db.add_student ("Иванов Иван", "5А", 123);
    db.add_student ("Петров Пётр", "5Б");  // без карточки

    var found = db.find_student_by_card (123);
    assert_nonnull (found);
    assert_cmpint ((int) found.id, CompareOperator.EQ, (int) id);
    assert_cmpstr (found.full_name, CompareOperator.EQ, "Иванов Иван");
    assert_cmpstr (found.group_name, CompareOperator.EQ, "5А");
    assert_null (db.find_student_by_card (999));

    var all = db.list_students ();
    assert_cmpint (all.length, CompareOperator.EQ, 2);
    assert_true (all[1].card_uid == null);

    // Привязать карточку ученику без карточки
    all[1].card_uid = 255 * 65536 + 65535;
    db.update_student (all[1]);
    assert_cmpstr (db.find_student_by_card (255 * 65536 + 65535).full_name, CompareOperator.EQ, "Петров Пётр");

    // Сменить карточку: прежняя остаётся в базе ничьей, её можно отдать другому
    found.card_uid = 124;
    db.update_student (found);
    assert_null (db.find_student_by_card (123));
    assert_nonnull (db.find_card (123));
    assert_cmpstr (db.find_student_by_card (124).full_name, CompareOperator.EQ, "Иванов Иван");
    var third = db.add_student ("Сидоров Сидор", "5В", 123);
    assert_cmpint ((int) db.find_student_by_card (123).id, CompareOperator.EQ, (int) third);

    // Забрать карточку
    found.card_uid = null;
    db.update_student (found);
    assert_null (db.find_student_by_card (124));
    assert_true (db.find_student_by_name ("Иванов Иван", "5А").card_uid == null);
    assert_null (db.find_student_by_name ("Иванов Иван", "5Б"));
}

void assert_constraint (Database db, string full_name, int64? card_uid) {
    try {
        db.add_student (full_name, "5А", card_uid);
        assert_not_reached ();
    } catch (DatabaseError e) {
        assert_true (e is DatabaseError.CONSTRAINT);
    }
}

void test_student_constraints () throws Error {
    var db = new Database (":memory:");
    db.add_student ("Иванов Иван", "5А", 123);
    assert_constraint (db, "Другой ученик", 123);  // карточка уже занята
    assert_constraint (db, "Отрицательный", -1);
    assert_constraint (db, "Серия больше байта", 256 * 65536);
    assert_constraint (db, "", 5);
    assert_cmpint (db.list_students ().length, CompareOperator.EQ, 1);
}

void test_record_meal () throws Error {
    var db = new Database (":memory:");
    var id = db.add_student ("Иванов Иван", "5А", 1);

    assert_true (db.record_meal (id, MealType.BREAKFAST, at (15, 8, 12)));
    assert_false (db.record_meal (id, MealType.BREAKFAST, at (15, 8, 13)));  // повторно
    assert_true (db.record_meal (id, MealType.LUNCH, at (15, 12, 30)));
    // На следующий день отметки снова свободны
    assert_true (db.record_meal (id, MealType.BREAKFAST, at (16, 8, 5)));

    var counts = db.count_meals (at (15, 0, 0));
    assert_cmpint (counts.breakfasts, CompareOperator.EQ, 1);
    assert_cmpint (counts.lunches, CompareOperator.EQ, 1);

    var student = db.find_student_by_card (1);
    var today = db.student_day (student, at (16, 0, 0));
    assert_cmpstr (today.breakfast_at, CompareOperator.EQ, "08:05:00");
    assert_null (today.lunch_at);
}

void test_unknown_cards () throws Error {
    var db = new Database (":memory:");
    var em = new CardRead () {
        raw = "Em-Marine[5500] 120,09886", card_type = "Em-Marine", code = "5500", series = 120, number = 9886
    };
    var mifare = new CardRead () {
        raw = "Mifare[658E6180045D85] 255,65535 UL (0144,00)", card_type = "Mifare",
        code = "658E6180045D85", series = 255, number = 65535
    };
    db.record_unknown_card (em, at (15, 8, 10));
    db.record_unknown_card (mifare, at (15, 8, 12));
    db.record_unknown_card (em, at (16, 9, 0));  // другой день

    var cards = db.unknown_cards (at (15, 0, 0));
    assert_cmpint (cards.length, CompareOperator.EQ, 2);
    assert_cmpstr (cards[0].raw, CompareOperator.EQ, "Em-Marine[5500] 120,09886");
    assert_cmpstr (cards[0].card_type, CompareOperator.EQ, "Em-Marine");
    assert_cmpstr (cards[0].code, CompareOperator.EQ, "5500");
    assert_cmpint (cards[0].series, CompareOperator.EQ, 120);
    assert_cmpint (cards[0].number, CompareOperator.EQ, 9886);
    assert_true (cards[0].uid == 120 * 65536 + 9886);
    assert_cmpstr (cards[0].scanned_at, CompareOperator.EQ, "08:10:00");
    assert_true (cards[1].uid == 0xFFFFFF);
    assert_cmpint (db.unknown_cards (at (17, 0, 0)).length, CompareOperator.EQ, 0);

    // Серия больше байта в базу не попадает
    try {
        db.record_unknown_card (new CardRead () {
            raw = "", card_type = "Тест", code = "", series = 256, number = 0
        }, at (15, 9, 0));
        assert_not_reached ();
    } catch (DatabaseError e) {
        assert_true (e is DatabaseError.CONSTRAINT);
    }

    // В журнал выдачи и выгрузку они не попадают
    assert_cmpint (db.day_records (at (15, 0, 0)).length, CompareOperator.EQ, 0);
    assert_cmpint ((int) db.last_meal_id (), CompareOperator.EQ, 0);
}

// Импорт знает только серию и номер, остальное дописывает первое прикладывание
void test_card_data () throws Error {
    var db = new Database (":memory:");
    var uid = 120 * 65536 + 9886;
    db.add_student ("Иванов Иван", "5А", uid);
    var card = db.find_card (uid);
    assert_cmpstr (card.card_type, CompareOperator.EQ, "");
    assert_cmpstr (card.code, CompareOperator.EQ, "");
    assert_null (db.find_card (uid + 1));

    // Тестовый режим записывает свои данные, но настоящая карточка их заменяет
    db.remember_card (new CardRead () {
        raw = "", card_type = CardRead.TEST_TYPE, code = "", series = 120, number = 9886
    });
    assert_cmpstr (db.find_card (uid).card_type, CompareOperator.EQ, CardRead.TEST_TYPE);
    db.remember_card (CardRead.parse ("Em-Marine[5500] 120,09886"));
    card = db.find_card (uid);
    assert_cmpstr (card.raw, CompareOperator.EQ, "Em-Marine[5500] 120,09886");
    assert_cmpstr (card.card_type, CompareOperator.EQ, "Em-Marine");
    assert_cmpstr (card.code, CompareOperator.EQ, "5500");

    // Записанное дальше не меняется — ни тестовым режимом, ни другим считыванием
    db.remember_card (new CardRead () {
        raw = "", card_type = CardRead.TEST_TYPE, code = "", series = 120, number = 9886
    });
    db.remember_card (CardRead.parse ("Mifare[658E6180045D85] 120,09886 UL (0144,00)"));
    assert_cmpstr (db.find_card (uid).code, CompareOperator.EQ, "5500");
    assert_cmpstr (db.find_student_by_card (uid).full_name, CompareOperator.EQ, "Иванов Иван");

    // Неизвестная карточка тоже попадает в таблицу карточек, и её можно отдать ученику
    db.record_unknown_card (CardRead.parse ("Em-Marine[5500] 001,00002"), at (15, 8, 0));
    assert_cmpstr (db.find_card (65536 + 2).code, CompareOperator.EQ, "5500");
    db.add_student ("Петров Пётр", "5Б", 65536 + 2);
    assert_cmpstr (db.find_card (65536 + 2).code, CompareOperator.EQ, "5500");
}

void test_record_meal_unknown_student () throws Error {
    var db = new Database (":memory:");
    try {
        db.record_meal (42, MealType.LUNCH, at (15, 12, 0));
        assert_not_reached ();
    } catch (DatabaseError e) {
        assert_true (e is DatabaseError.CONSTRAINT);
    }
}

void test_day_records () throws Error {
    var db = new Database (":memory:");
    var b = db.add_student ("Борисов Борис", "5Б", 2);
    var a = db.add_student ("Алексеев Алексей", "5А", 1);
    db.add_student ("Не ел", "5А", 3);

    db.record_meal (b, MealType.LUNCH, at (15, 12, 40));
    db.record_meal (a, MealType.BREAKFAST, at (15, 8, 10));
    db.record_meal (a, MealType.LUNCH, at (15, 12, 30));
    db.record_meal (a, MealType.LUNCH, at (14, 12, 0));

    var records = db.day_records (at (15, 0, 0));
    assert_cmpint (records.length, CompareOperator.EQ, 2);  // кто не ел, в списке нет
    assert_cmpstr (records[0].student.full_name, CompareOperator.EQ, "Алексеев Алексей");
    assert_cmpstr (records[0].breakfast_at, CompareOperator.EQ, "08:10:00");
    assert_cmpstr (records[0].lunch_at, CompareOperator.EQ, "12:30:00");
    assert_cmpstr (records[1].student.full_name, CompareOperator.EQ, "Борисов Борис");
    assert_null (records[1].breakfast_at);

    var days = db.meal_days ();
    assert_cmpint (days.length, CompareOperator.EQ, 2);
    assert_cmpstr (days[0], CompareOperator.EQ, "2026-10-14");
    assert_cmpstr (days[1], CompareOperator.EQ, "2026-10-15");
    assert_cmpint (db.meal_days (2026).length, CompareOperator.EQ, 2);  // учебный 2026–2027
    assert_cmpint (db.meal_days (2025).length, CompareOperator.EQ, 0);
}

void test_school_years () throws Error {
    // Учебный год по году начала: сентябрь–июнь, лето — к закончившемуся году
    assert_cmpint (Database.school_year_of (new DateTime.local (2026, 9, 1, 0, 0, 0)), CompareOperator.EQ, 2026);
    assert_cmpint (Database.school_year_of (new DateTime.local (2026, 12, 31, 0, 0, 0)), CompareOperator.EQ, 2026);
    assert_cmpint (Database.school_year_of (new DateTime.local (2027, 6, 30, 0, 0, 0)), CompareOperator.EQ, 2026);
    assert_cmpint (Database.school_year_of (new DateTime.local (2027, 7, 15, 0, 0, 0)), CompareOperator.EQ, 2026);
    assert_cmpint (Database.school_year_of (new DateTime.local (2026, 8, 31, 0, 0, 0)), CompareOperator.EQ, 2025);

    var db = new Database (":memory:");
    var id = db.add_student ("Иванов Иван", "5А", 1);
    db.record_meal (id, MealType.LUNCH, new DateTime.local (2024, 6, 30, 12, 0, 0));  // 2023–2024
    db.record_meal (id, MealType.LUNCH, new DateTime.local (2024, 8, 20, 12, 0, 0));  // лето → 2023–2024
    db.record_meal (id, MealType.LUNCH, new DateTime.local (2024, 9, 1, 12, 0, 0));   // 2024–2025
    db.record_meal (id, MealType.LUNCH, new DateTime.local (2025, 5, 25, 12, 0, 0));  // 2024–2025

    assert_cmpint (db.meal_days (2023).length, CompareOperator.EQ, 2);
    assert_cmpint (db.meal_days (2024).length, CompareOperator.EQ, 2);
    var years = db.changed_school_years ();
    assert_cmpint (years.length, CompareOperator.EQ, 2);
    assert_cmpint (years[0], CompareOperator.EQ, 2023);
    assert_cmpint (years[1], CompareOperator.EQ, 2024);

    // Все годы с выдачей — и после выгрузки
    var now = new DateTime.now_local ();
    db.mark_exported (now, "/tmp/a.xlsx", now, db.last_meal_id ());
    assert_cmpint (db.changed_school_years ().length, CompareOperator.EQ, 0);
    years = db.meal_school_years ();
    assert_cmpint (years.length, CompareOperator.EQ, 2);
    assert_cmpint (years[0], CompareOperator.EQ, 2023);
    assert_cmpint (years[1], CompareOperator.EQ, 2024);
}

void test_settings () throws Error {
    var db = new Database (":memory:");
    assert_null (db.get_setting ("auto_meal"));
    db.set_setting ("auto_meal", "false");
    db.set_setting ("auto_meal", "true");  // повторная запись заменяет значение
    assert_cmpstr (db.get_setting ("auto_meal"), CompareOperator.EQ, "true");
}

void test_exports () throws Error {
    var db = new Database (":memory:");
    assert_null (db.last_export_date ());
    assert_cmpint ((int) db.last_meal_id (), CompareOperator.EQ, 0);
    db.mark_exported (at (14, 0, 0), "/tmp/a.xlsx", at (15, 0, 1), 0);
    db.mark_exported (at (15, 0, 0), "/tmp/a.xlsx", at (15, 18, 0), 0);
    db.mark_exported (at (15, 0, 0), "/tmp/a.xlsx", at (15, 19, 0), 0);  // повторно за тот же день
    assert_cmpstr (db.last_export_date (), CompareOperator.EQ, "2026-10-15");
}

// Изменённые годы — по номерам записей, а не по часам
void test_changed_after_clock_back () throws Error {
    var db = new Database (":memory:");
    var id = db.add_student ("Иванов Иван", "5А", 1);
    db.record_meal (id, MealType.BREAKFAST, at (15, 8, 0));
    var now = new DateTime.now_local ();
    db.mark_exported (now, "/tmp/a.xlsx", now, db.last_meal_id ());
    assert_cmpint (db.changed_school_years ().length, CompareOperator.EQ, 0);

    // Часы перевели назад: запись «раньше» выгрузки, но она новая
    db.record_meal (id, MealType.LUNCH, at (15, 7, 0));
    var years = db.changed_school_years ();
    assert_cmpint (years.length, CompareOperator.EQ, 1);
    assert_cmpint (years[0], CompareOperator.EQ, 2026);
}

// База версии 2: выгрузки без номера записи — все годы считаются изменёнными
void test_migrate_from_2 () throws Error {
    var dir = DirUtils.make_tmp ("stolovaya-test-XXXXXX");
    var path = Path.build_filename (dir, "canteen.db");
    Sqlite.Database old;
    Sqlite.Database.open_v2 (path, out old);
    assert_true (old.exec ("""
        CREATE TABLE students (id INTEGER PRIMARY KEY, card_uid INTEGER UNIQUE,
                               full_name TEXT NOT NULL, group_name TEXT NOT NULL);
        CREATE TABLE meals (id INTEGER PRIMARY KEY, student_id INTEGER NOT NULL, meal_date TEXT NOT NULL,
                            meal_type TEXT NOT NULL, issued_at TEXT NOT NULL);
        CREATE TABLE exports (export_date TEXT PRIMARY KEY, file_path TEXT NOT NULL, done_at TEXT NOT NULL);
        CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        INSERT INTO students VALUES (1, 1, 'Иванов Иван', '5А');
        INSERT INTO meals VALUES (1, 1, '2026-10-15', 'lunch', '12:00:00');
        INSERT INTO exports VALUES ('2026-10-16', '/tmp/a.xlsx', '2026-10-16 00:00:00');
        PRAGMA user_version = 2;
    """) == Sqlite.OK);
    old = null;

    var db = new Database (path);
    assert_cmpint (db.schema_version (), CompareOperator.EQ, 6);
    var years = db.changed_school_years ();
    assert_cmpint (years.length, CompareOperator.EQ, 1);
    assert_cmpint (years[0], CompareOperator.EQ, 2026);

    // ФИО и группа в старых записях — нынешние: изменёнными не показываются
    var records = db.day_records (at (15, 0, 0));
    assert_cmpstr (records[0].issued_name, CompareOperator.EQ, "Иванов Иван");
    assert_cmpstr (records[0].issued_group, CompareOperator.EQ, "5А");
    assert_null (records[0].change_note ());
    db = null;

    foreach (var name in new string[] { "canteen.db", "canteen.db-wal", "canteen.db-shm" }) {
        FileUtils.remove (Path.build_filename (dir, name));
    }
    DirUtils.remove (dir);
}

// База версии 5: карточки учеников и неизвестные переезжают в cards,
// прикладывания неизвестных — в unknown_scans
void test_migrate_from_5 () throws Error {
    var dir = DirUtils.make_tmp ("stolovaya-test-XXXXXX");
    var path = Path.build_filename (dir, "canteen.db");
    Sqlite.Database old;
    Sqlite.Database.open_v2 (path, out old);
    assert_true (old.exec ("""
        CREATE TABLE students (id INTEGER PRIMARY KEY, card_uid INTEGER UNIQUE CHECK (card_uid >= 0),
                               full_name TEXT NOT NULL CHECK (full_name <> ''), group_name TEXT NOT NULL);
        CREATE TABLE meals (id INTEGER PRIMARY KEY, student_id INTEGER NOT NULL REFERENCES students (id),
                            meal_date TEXT NOT NULL, meal_type TEXT NOT NULL, issued_at TEXT NOT NULL,
                            full_name TEXT, group_name TEXT, UNIQUE (student_id, meal_date, meal_type));
        CREATE TABLE exports (export_date TEXT PRIMARY KEY, file_path TEXT NOT NULL, done_at TEXT NOT NULL,
                              last_meal_id INTEGER);
        CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE unknown_cards (id INTEGER PRIMARY KEY, raw TEXT NOT NULL, card_type TEXT NOT NULL,
                                    code TEXT NOT NULL, series INTEGER NOT NULL, number INTEGER NOT NULL,
                                    scan_date TEXT NOT NULL, scanned_at TEXT NOT NULL);
        CREATE TABLE export_queue (id INTEGER PRIMARY KEY, school_year INTEGER NOT NULL);
        INSERT INTO students VALUES (1, 65536 + 1, 'Иванов Иван', '5А'), (2, NULL, 'Петров Пётр', '5Б');
        INSERT INTO meals VALUES (1, 1, '2026-10-15', 'lunch', '12:00:00', 'Иванов Иван', '5А');
        INSERT INTO exports VALUES ('2026-10-16', '/tmp/a.xlsx', '2026-10-16 00:00:00', 1);
        INSERT INTO unknown_cards VALUES
            (1, '', 'Тест', '', 0, 7, '2026-10-15', '08:00:00'),
            (2, 'Em-Marine[5500] 000,00007', 'Em-Marine', '5500', 0, 7, '2026-10-15', '08:05:00'),
            (3, 'Em-Marine[5500] 001,00001', 'Em-Marine', '5500', 1, 1, '2026-10-14', '09:00:00'),
            (4, 'Em-Marine[5500] 000,00007', 'мусор', '!!', 0, 7, '2026-10-16', '08:00:00'),
            (5, 'Em-Marine[5500] 000,00009', 'мусор', '!!', 0, 9, '2026-10-16', '08:01:00');
        PRAGMA user_version = 5;
    """) == Sqlite.OK);
    old = null;

    var db = new Database (path);
    assert_cmpint (db.schema_version (), CompareOperator.EQ, 6);

    // Карточка ученика — с данными из его прежних прикладываний неизвестной
    var student = db.find_student_by_card (65536 + 1);
    assert_cmpstr (student.full_name, CompareOperator.EQ, "Иванов Иван");
    assert_cmpstr (db.find_card (65536 + 1).code, CompareOperator.EQ, "5500");
    assert_true (db.find_student_by_name ("Петров Пётр", "5Б").card_uid == null);

    // Неизвестная карточка — одна запись с последними целыми данными
    // (испорченные и тестовые пропускаются), прикладывания — все
    assert_cmpstr (db.find_card (7).card_type, CompareOperator.EQ, "Em-Marine");
    assert_cmpstr (db.find_card (9).card_type, CompareOperator.EQ, "");  // допишет следующее прикладывание
    assert_cmpint (db.unknown_cards (at (16, 0, 0)).length, CompareOperator.EQ, 2);
    var scans = db.unknown_cards (at (15, 0, 0));
    assert_cmpint (scans.length, CompareOperator.EQ, 2);
    assert_cmpstr (scans[0].scanned_at, CompareOperator.EQ, "08:00:00");
    assert_true (scans[1].uid == 7);
    assert_cmpint (db.unknown_cards (at (14, 0, 0)).length, CompareOperator.EQ, 1);

    // Журнал на месте, внешние ключи работают, триггер переименования — тоже
    assert_cmpint (db.day_records (at (15, 0, 0)).length, CompareOperator.EQ, 1);
    assert_true (db.record_meal (student.id, MealType.LUNCH, at (16, 12, 0)));
    try {
        db.record_meal (42, MealType.LUNCH, at (16, 12, 0));
        assert_not_reached ();
    } catch (DatabaseError e) {
        assert_true (e is DatabaseError.CONSTRAINT);
    }
    db.mark_exported (at (16, 0, 0), "/tmp/a.xlsx", at (16, 13, 0), db.last_meal_id ());
    student.group_name = "6А";
    db.update_student (student);
    assert_cmpint (db.changed_school_years ().length, CompareOperator.EQ, 1);
    db = null;

    foreach (var name in new string[] { "canteen.db", "canteen.db-wal", "canteen.db-shm" }) {
        FileUtils.remove (Path.build_filename (dir, name));
    }
    DirUtils.remove (dir);
}

// Ученика переименовали и перевели после выдачи: видно и прежнее, и нынешнее,
// а годы, где он получал питание, встают в очередь на пересборку
void test_student_renamed () throws Error {
    var db = new Database (":memory:");
    var id = db.add_student ("Иванова Мария", "5А", 1);
    db.add_student ("Петров Пётр", "5Б", 2);
    db.record_meal (id, MealType.LUNCH, at (15, 12, 0));
    db.record_meal (id, MealType.LUNCH, new DateTime.local (2025, 10, 1, 12, 0, 0));
    var now = new DateTime.now_local ();
    db.mark_exported (now, "/tmp/a.xlsx", now, db.last_meal_id ());
    assert_cmpint (db.changed_school_years ().length, CompareOperator.EQ, 0);

    var student = db.find_student_by_card (1);
    student.full_name = "Смирнова Мария";
    student.group_name = "6А";
    db.update_student (student);

    var record = db.day_records (at (15, 0, 0))[0];
    assert_cmpstr (record.issued_name, CompareOperator.EQ, "Иванова Мария");
    assert_cmpstr (record.issued_group, CompareOperator.EQ, "5А");
    assert_cmpstr (record.student.full_name, CompareOperator.EQ, "Смирнова Мария");
    assert_cmpstr (record.student.group_name, CompareOperator.EQ, "6А");
    assert_true (record.name_changed && record.group_changed);
    var note = record.change_note ();
    assert_true ("«Иванова Мария»" in note && "«Смирнова Мария»" in note);
    assert_true ("«5А»" in note && "«6А»" in note);

    // Новая выдача — уже с новыми ФИО и группой
    db.record_meal (id, MealType.LUNCH, at (16, 12, 0));
    assert_null (db.day_records (at (16, 0, 0))[0].change_note ());

    // Пересобрать оба года, где ученик получал питание
    var years = db.changed_school_years ();
    assert_cmpint (years.length, CompareOperator.EQ, 2);
    assert_true (2025 in years && 2026 in years);
    db.mark_exported (now, "/tmp/a.xlsx", now, db.last_meal_id (), db.last_queued_id ());
    assert_cmpint (db.changed_school_years ().length, CompareOperator.EQ, 0);

    // Сохранили без изменений (как кнопка «Записать» в DB Browser) — не в очередь
    db.update_student (db.find_student_by_card (1));
    assert_cmpint (db.changed_school_years ().length, CompareOperator.EQ, 0);
}

// Базу держит другая программа (DB Browser с незаписанными изменениями):
// понятная ошибка, а не «database is locked»
void test_busy () throws Error {
    var dir = DirUtils.make_tmp ("stolovaya-test-XXXXXX");
    var path = Path.build_filename (dir, "canteen.db");
    var db = new Database (path);
    var id = db.add_student ("Иванов Иван", "5А", 1);
    var version = db.data_version ();

    Sqlite.Database other;
    Sqlite.Database.open_v2 (path, out other);
    assert_true (other.exec ("UPDATE students SET full_name = 'Иванов Илья'") == Sqlite.OK);
    assert_true (db.data_version () != version);  // правку другой программой видно

    assert_false (db.write_locked ());
    assert_true (other.exec ("BEGIN IMMEDIATE") == Sqlite.OK);
    assert_true (db.write_locked ());
    try {
        db.record_meal (id, MealType.LUNCH, at (15, 12, 0));
        assert_not_reached ();
    } catch (DatabaseError.BUSY e) {
        assert_true ("занята другой программой" in e.message);
    }
    other.exec ("ROLLBACK");
    assert_false (db.write_locked ());
    assert_true (db.record_meal (id, MealType.LUNCH, at (15, 12, 0)));
    other = null;
    db = null;

    foreach (var name in new string[] { "canteen.db", "canteen.db-wal", "canteen.db-shm" }) {
        FileUtils.remove (Path.build_filename (dir, name));
    }
    DirUtils.remove (dir);
}

// Базу держат для записи уже при запуске (миграция не может начаться) —
// тоже понятная ошибка BUSY
void test_busy_on_open () throws Error {
    var dir = DirUtils.make_tmp ("stolovaya-test-XXXXXX");
    var path = Path.build_filename (dir, "canteen.db");

    Sqlite.Database other;
    Sqlite.Database.open_v2 (path, out other);
    assert_true (other.exec ("BEGIN IMMEDIATE") == Sqlite.OK);
    try {
        new Database (path);
        assert_not_reached ();
    } catch (DatabaseError.BUSY e) {
        assert_true ("занята другой программой" in e.message);
    }
    other.exec ("ROLLBACK");
    other = null;
    var db = new Database (path);
    assert_cmpint (db.schema_version (), CompareOperator.EQ, 6);
    db = null;

    foreach (var name in new string[] { "canteen.db", "canteen.db-wal", "canteen.db-shm" }) {
        FileUtils.remove (Path.build_filename (dir, name));
    }
    DirUtils.remove (dir);
}

void test_reopen_file () throws Error {
    var dir = DirUtils.make_tmp ("stolovaya-test-XXXXXX");
    var path = Path.build_filename (dir, "sub", "canteen.db");  // папка sub создаётся сама

    var db = new Database (path);
    db.add_student ("Иванов Иван", "5А", 7);
    db = null;  // закрыть

    db = new Database (path);  // миграция не должна повториться
    assert_cmpint (db.schema_version (), CompareOperator.EQ, 6);
    assert_nonnull (db.find_student_by_card (7));
    db = null;

    foreach (var name in new string[] { "canteen.db", "canteen.db-wal", "canteen.db-shm" }) {
        FileUtils.remove (Path.build_filename (dir, "sub", name));
    }
    DirUtils.remove (Path.build_filename (dir, "sub"));
    DirUtils.remove (dir);
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/database/schema", () => wrap (test_schema));
    Test.add_func ("/database/student-renamed", () => wrap (test_student_renamed));
    Test.add_func ("/database/busy", () => wrap (test_busy));
    Test.add_func ("/database/busy-on-open", () => wrap (test_busy_on_open));
    Test.add_func ("/database/students", () => wrap (test_students));
    Test.add_func ("/database/student-constraints", () => wrap (test_student_constraints));
    Test.add_func ("/database/record-meal", () => wrap (test_record_meal));
    Test.add_func ("/database/unknown-cards", () => wrap (test_unknown_cards));
    Test.add_func ("/database/card-data", () => wrap (test_card_data));
    Test.add_func ("/database/record-meal-unknown-student", () => wrap (test_record_meal_unknown_student));
    Test.add_func ("/database/day-records", () => wrap (test_day_records));
    Test.add_func ("/database/school-years", () => wrap (test_school_years));
    Test.add_func ("/database/settings", () => wrap (test_settings));
    Test.add_func ("/database/exports", () => wrap (test_exports));
    Test.add_func ("/database/changed-after-clock-back", () => wrap (test_changed_after_clock_back));
    Test.add_func ("/database/migrate-from-2", () => wrap (test_migrate_from_2));
    Test.add_func ("/database/migrate-from-5", () => wrap (test_migrate_from_5));
    Test.add_func ("/database/reopen-file", () => wrap (test_reopen_file));
    return Test.run ();
}

delegate void TestBody () throws Error;

// Любая неожиданная ошибка базы — провал теста с её текстом
void wrap (TestBody body) {
    try {
        body ();
    } catch (Error e) {
        error ("%s", e.message);
    }
}
