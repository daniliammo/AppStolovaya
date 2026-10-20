// База данных SQLite: ученики, журнал выдачи питания, отметки о выгрузках.
// Все SQL-запросы программы собраны в этом файле.
//
// Дата и время хранятся строками в местном времени:
// дата 'YYYY-MM-DD', время 'HH:MM:SS'. Их можно сравнивать как строки.

public errordomain DatabaseError {
    OPEN,
    QUERY,
    // Нарушено ограничение: номер карточки уже занят, пустое ФИО и т.п.
    CONSTRAINT
}

public enum MealType {
    BREAKFAST,
    LUNCH;

    public string to_db () {
        return this == BREAKFAST ? "breakfast" : "lunch";
    }
}

public class Student {
    public int64 id;
    public int64? card_uid;  // null — карточка ещё не привязана
    public string full_name;
    public string group_name;
}

// Кто и когда получил питание в выбранный день (для истории и выгрузки)
public class DayRecord {
    public Student student;
    public string? breakfast_at;  // 'HH:MM:SS' или null, если не получал
    public string? lunch_at;
}

public struct MealCounts {
    public int breakfasts;
    public int lunches;
}

public class Database {
    // Миграции схемы по порядку. Номер применённой хранится в PRAGMA user_version.
    // Новые изменения схемы — только новым элементом в конце массива.
    private const string[] MIGRATIONS = {
        """
        CREATE TABLE students (
            id          INTEGER PRIMARY KEY,
            card_uid    INTEGER UNIQUE CHECK (card_uid >= 0),
            full_name   TEXT    NOT NULL CHECK (full_name <> ''),
            group_name  TEXT    NOT NULL
        );

        CREATE TABLE meals (
            id          INTEGER PRIMARY KEY,
            student_id  INTEGER NOT NULL REFERENCES students (id),
            meal_date   TEXT    NOT NULL,
            meal_type   TEXT    NOT NULL CHECK (meal_type IN ('breakfast', 'lunch')),
            issued_at   TEXT    NOT NULL,
            UNIQUE (student_id, meal_date, meal_type)
        );
        CREATE INDEX meals_by_date ON meals (meal_date);

        CREATE TABLE exports (
            export_date TEXT PRIMARY KEY,
            file_path   TEXT NOT NULL,
            done_at     TEXT NOT NULL
        );
        """,
        // 2: настройки программы (ключ — значение)
        """
        CREATE TABLE settings (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """,
        // 3: что уже выгружено — по номеру последней записи журнала, а не по
        // времени: время зависит от часов компьютера, а их могут перевести назад.
        // У прежних выгрузок номера нет — один раз пересоберутся все годы.
        """
        ALTER TABLE exports ADD COLUMN last_meal_id INTEGER;
        """
    };

    private Sqlite.Database db;

    // path — путь к файлу базы или ":memory:" (для тестов)
    public Database (string path) throws DatabaseError {
        if (path != ":memory:") {
            DirUtils.create_with_parents (Path.get_dirname (path), 0700);
        }

        if (Sqlite.Database.open_v2 (path, out db) != Sqlite.OK) {
            throw new DatabaseError.OPEN ("Не удалось открыть базу %s: %s",
                path, db != null ? db.errmsg () : "нет памяти");
        }

        exec ("PRAGMA foreign_keys = ON");
        exec ("PRAGMA journal_mode = WAL");
        migrate ();
    }

    public int schema_version () throws DatabaseError {
        var stmt = prepare ("PRAGMA user_version");
        stmt.step ();
        return stmt.column_int (0);
    }

    // --- Ученики ---

    public int64 add_student (string full_name, string group_name, int64? card_uid = null) throws DatabaseError {
        var stmt = prepare ("INSERT INTO students (full_name, group_name, card_uid) VALUES (?, ?, ?)");
        stmt.bind_text (1, full_name);
        stmt.bind_text (2, group_name);
        bind_nullable_int64 (stmt, 3, card_uid);
        step_done (stmt);
        return db.last_insert_rowid ();
    }

    public void update_student (Student student) throws DatabaseError {
        var stmt = prepare ("UPDATE students SET full_name = ?, group_name = ?, card_uid = ? WHERE id = ?");
        stmt.bind_text (1, student.full_name);
        stmt.bind_text (2, student.group_name);
        bind_nullable_int64 (stmt, 3, student.card_uid);
        stmt.bind_int64 (4, student.id);
        step_done (stmt);
    }

    public Student? find_student_by_card (int64 card_uid) throws DatabaseError {
        var stmt = prepare ("SELECT id, card_uid, full_name, group_name FROM students WHERE card_uid = ?");
        stmt.bind_int64 (1, card_uid);
        return step_row (stmt) ? read_student (stmt, 0) : null;
    }

    public GenericArray<Student> list_students () throws DatabaseError {
        var stmt = prepare ("""
            SELECT id, card_uid, full_name, group_name FROM students
            ORDER BY group_name, full_name
        """);
        var result = new GenericArray<Student> ();
        while (step_row (stmt)) {
            result.add (read_student (stmt, 0));
        }
        return result;
    }

    // --- Журнал выдачи ---

    // Списать завтрак или обед. Возвращает false, если в этот день
    // ученик его уже получил (второй раз не списывается).
    public bool record_meal (int64 student_id, MealType type, DateTime when) throws DatabaseError {
        var stmt = prepare ("""
            INSERT INTO meals (student_id, meal_date, meal_type, issued_at) VALUES (?, ?, ?, ?)
            ON CONFLICT (student_id, meal_date, meal_type) DO NOTHING
        """);
        stmt.bind_int64 (1, student_id);
        stmt.bind_text (2, format_date (when));
        stmt.bind_text (3, type.to_db ());
        stmt.bind_text (4, when.format ("%H:%M:%S"));
        step_done (stmt);
        return db.changes () == 1;
    }

    public MealCounts count_meals (DateTime day) throws DatabaseError {
        var stmt = prepare ("""
            SELECT count(*) FILTER (WHERE meal_type = 'breakfast'),
                   count(*) FILTER (WHERE meal_type = 'lunch')
            FROM meals WHERE meal_date = ?
        """);
        stmt.bind_text (1, format_date (day));
        step_row (stmt);
        return { stmt.column_int (0), stmt.column_int (1) };
    }

    // Что ученик получил в этот день (для окна ученика)
    public DayRecord student_day (Student student, DateTime day) throws DatabaseError {
        var stmt = prepare ("""
            SELECT max(issued_at) FILTER (WHERE meal_type = 'breakfast'),
                   max(issued_at) FILTER (WHERE meal_type = 'lunch')
            FROM meals WHERE student_id = ? AND meal_date = ?
        """);
        stmt.bind_int64 (1, student.id);
        stmt.bind_text (2, format_date (day));
        step_row (stmt);
        return new DayRecord () {
            student = student,
            breakfast_at = nullable_text (stmt, 0),
            lunch_at = nullable_text (stmt, 1)
        };
    }

    // Все, кто получал питание в этот день, по группам и ФИО
    public GenericArray<DayRecord> day_records (DateTime day) throws DatabaseError {
        var stmt = prepare ("""
            SELECT s.id, s.card_uid, s.full_name, s.group_name,
                   max(m.issued_at) FILTER (WHERE m.meal_type = 'breakfast'),
                   max(m.issued_at) FILTER (WHERE m.meal_type = 'lunch')
            FROM meals AS m JOIN students AS s ON s.id = m.student_id
            WHERE m.meal_date = ?
            GROUP BY s.id
            ORDER BY s.group_name, s.full_name
        """);
        stmt.bind_text (1, format_date (day));
        var result = new GenericArray<DayRecord> ();
        while (step_row (stmt)) {
            result.add (new DayRecord () {
                student = read_student (stmt, 0),
                breakfast_at = nullable_text (stmt, 4),
                lunch_at = nullable_text (stmt, 5)
            });
        }
        return result;
    }

    // Дни, в которые была выдача ('YYYY-MM-DD', по возрастанию): листы выгрузки.
    // school_year — учебный год по году начала (2026 — это 2026–2027), 0 — все дни.
    public GenericArray<string> meal_days (int school_year = 0) throws DatabaseError {
        var stmt = prepare ("""
            SELECT DISTINCT meal_date FROM meals
            WHERE ?1 = 0 OR meal_date BETWEEN ?1 || '-09-01' AND (?1 + 1) || '-08-31'
            ORDER BY meal_date
        """);
        stmt.bind_int (1, school_year);
        var result = new GenericArray<string> ();
        while (step_row (stmt)) {
            result.add (stmt.column_text (0));
        }
        return result;
    }

    // --- Выгрузки ---

    // По какой день включительно сделана последняя выгрузка ('YYYY-MM-DD') или null
    public string? last_export_date () throws DatabaseError {
        var stmt = prepare ("SELECT max(export_date) FROM exports");
        step_row (stmt);
        return nullable_text (stmt, 0);
    }

    // Учебные годы (по году начала), в которых после последней выгрузки появились
    // новые записи (если выгрузок не было — все). Их файлы нужно пересобрать.
    public int[] changed_school_years () throws DatabaseError {
        return school_years ("WHERE id > coalesce ((SELECT max (last_meal_id) FROM exports), 0)");
    }

    // Номер последней записи журнала (0 — записей нет). Новые записи
    // получают номера больше, поэтому по нему видно, что уже выгружено.
    public int64 last_meal_id () throws DatabaseError {
        var stmt = prepare ("SELECT coalesce (max (id), 0) FROM meals");
        step_row (stmt);
        return stmt.column_int64 (0);
    }

    // last_meal_id — до какой записи журнала включительно выгружено
    public void mark_exported (DateTime day, string file_path, DateTime done_at,
                               int64 last_meal_id) throws DatabaseError {
        var stmt = prepare ("""
            INSERT INTO exports (export_date, file_path, done_at, last_meal_id) VALUES (?, ?, ?, ?)
            ON CONFLICT (export_date) DO UPDATE SET file_path = excluded.file_path,
                done_at = excluded.done_at, last_meal_id = excluded.last_meal_id
        """);
        stmt.bind_text (1, format_date (day));
        stmt.bind_text (2, file_path);
        stmt.bind_text (3, done_at.format ("%Y-%m-%d %H:%M:%S"));
        stmt.bind_int64 (4, last_meal_id);
        step_done (stmt);
    }

    // --- Настройки ---

    // Значение настройки или null, если она ещё не задавалась
    public string? get_setting (string key) throws DatabaseError {
        var stmt = prepare ("SELECT value FROM settings WHERE key = ?");
        stmt.bind_text (1, key);
        return step_row (stmt) ? stmt.column_text (0) : null;
    }

    public void set_setting (string key, string value) throws DatabaseError {
        var stmt = prepare ("""
            INSERT INTO settings (key, value) VALUES (?, ?)
            ON CONFLICT (key) DO UPDATE SET value = excluded.value
        """);
        stmt.bind_text (1, key);
        stmt.bind_text (2, value);
        step_done (stmt);
    }

    // --- Внутреннее ---

    // Учебный год, к которому относится день, по году начала: сентябрь 2026 —
    // июнь 2027 это 2026. Июль и август (каникулы) относятся к закончившемуся году.
    public static int school_year_of (DateTime day) {
        return day.get_month () >= 9 ? day.get_year () : day.get_year () - 1;
    }

    public static string format_date (DateTime day) {
        return day.format ("%Y-%m-%d");
    }

    // Учебные годы записей журнала, подходящих под where, по возрастанию.
    // Формула та же, что в school_year_of (): январь–август — год начала на 1 меньше.
    private int[] school_years (string where) throws DatabaseError {
        var stmt = prepare ("""
            SELECT DISTINCT CAST (substr (meal_date, 1, 4) AS INTEGER)
                          - (CAST (substr (meal_date, 6, 2) AS INTEGER) < 9)
            FROM meals %s
            ORDER BY 1
        """.printf (where));
        int[] result = {};
        while (step_row (stmt)) {
            result += stmt.column_int (0);
        }
        return result;
    }

    private void migrate () throws DatabaseError {
        for (int version = schema_version (); version < MIGRATIONS.length; version++) {
            exec ("BEGIN");
            try {
                exec (MIGRATIONS[version]);
                exec ("PRAGMA user_version = %d".printf (version + 1));
                exec ("COMMIT");
            } catch (DatabaseError e) {
                db.exec ("ROLLBACK");
                throw e;
            }
        }
    }

    private void exec (string sql) throws DatabaseError {
        string errmsg;
        if (db.exec (sql, null, out errmsg) != Sqlite.OK) {
            throw new DatabaseError.QUERY ("%s", errmsg);
        }
    }

    private Sqlite.Statement prepare (string sql) throws DatabaseError {
        Sqlite.Statement stmt;
        if (db.prepare_v2 (sql, -1, out stmt) != Sqlite.OK) {
            throw new DatabaseError.QUERY ("%s\n%s", db.errmsg (), sql);
        }
        return stmt;
    }

    // Шаг запроса, который возвращает строки: true — есть строка, false — строки кончились
    private bool step_row (Sqlite.Statement stmt) throws DatabaseError {
        switch (stmt.step ()) {
        case Sqlite.ROW:
            return true;
        case Sqlite.DONE:
            return false;
        default:
            throw new DatabaseError.QUERY ("%s", db.errmsg ());
        }
    }

    // Шаг запроса без результата (INSERT, UPDATE)
    private void step_done (Sqlite.Statement stmt) throws DatabaseError {
        switch (stmt.step ()) {
        case Sqlite.DONE:
            return;
        case Sqlite.CONSTRAINT:
            throw new DatabaseError.CONSTRAINT ("%s", db.errmsg ());
        default:
            throw new DatabaseError.QUERY ("%s", db.errmsg ());
        }
    }

    private static void bind_nullable_int64 (Sqlite.Statement stmt, int index, int64? value) {
        if (value == null) {
            stmt.bind_null (index);
        } else {
            stmt.bind_int64 (index, value);
        }
    }

    private static string? nullable_text (Sqlite.Statement stmt, int column) {
        return stmt.column_type (column) == Sqlite.NULL ? null : stmt.column_text (column);
    }

    // Столбцы id, card_uid, full_name, group_name начиная с first
    private static Student read_student (Sqlite.Statement stmt, int first) {
        return new Student () {
            id = stmt.column_int64 (first),
            card_uid = stmt.column_type (first + 1) == Sqlite.NULL ? null : (int64?) stmt.column_int64 (first + 1),
            full_name = stmt.column_text (first + 2),
            group_name = stmt.column_text (first + 3)
        };
    }
}
