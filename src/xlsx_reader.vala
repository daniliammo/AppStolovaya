// Чтение первого листа таблицы Excel (.xlsx) — для импорта учеников.
// .xlsx — zip-архив с XML (ECMA-376):
//   xl/workbook.xml            — листы по порядку, у каждого r:id;
//   xl/_rels/workbook.xml.rels — в каком файле лист с этим r:id;
//   xl/sharedStrings.xml       — общие строки: ячейка с t="s" хранит номер строки;
//   xl/worksheets/sheetN.xml   — строки <row r="1"> и ячейки <c r="A1" t="…"><v>…</v></c>.
// Формулы не вычисляются — берётся значение, которое сохранил Excel.
// Для разбора XML хватает GMarkup из GLib.

public errordomain XlsxError {
    FORMAT
}

// Строка листа
public class SheetRow {
    public int number;  // номер строки в Excel, с 1
    public string[] cells = {};  // значения по столбцам A, B, C…; пустые ячейки — ""
}

public class XlsxReader {
    private Unzip.Archive? archive;
    private string name;  // имя файла для сообщений

    // Строки первого листа по порядку. Пустых строк Excel не сохраняет.
    public static GenericArray<SheetRow> read_first_sheet (string path) throws XlsxError {
        var reader = new XlsxReader (path);
        return reader.read_sheet (reader.first_sheet (), reader.shared_strings ());
    }

    private XlsxReader (string path) throws XlsxError {
        name = Path.get_basename (path);
        archive = Unzip.Archive.open (path);
        if (archive == null) {
            throw new XlsxError.FORMAT (@"«$name» — не таблица Excel. Файл .xls сохраните в Excel как .xlsx");
        }
    }

    // Файл листа из архива: первый лист книги
    private string first_sheet () throws XlsxError {
        var workbook = new WorkbookParser ();
        parse (workbook, read_entry ("xl/workbook.xml"));
        var relations = new RelationsParser ();
        parse (relations, read_entry ("xl/_rels/workbook.xml.rels"));
        var target = workbook.first_sheet_id != null ? relations.targets[workbook.first_sheet_id] : null;
        if (target == null) {
            throw broken ();
        }
        // Путь — от папки xl/ или от корня архива, если начинается с «/»
        return target.has_prefix ("/") ? target.substring (1) : @"xl/$target";
    }

    // Общие строки; если в книге нет текста, нет и файла
    private GenericArray<string> shared_strings () throws XlsxError {
        var parser = new SharedStringsParser ();
        if (archive.locate_file ("xl/sharedStrings.xml", 1) == Unzip.OK) {
            parse (parser, read_entry ("xl/sharedStrings.xml"));
        }
        return parser.strings;
    }

    private GenericArray<SheetRow> read_sheet (string path, GenericArray<string> shared) throws XlsxError {
        var parser = new SheetParser (shared);
        parse (parser, read_entry (path));
        return parser.rows;
    }

    // Файл из архива текстом
    private string read_entry (string path) throws XlsxError {
        if (archive.locate_file (path, 1) != Unzip.OK || archive.open_current_file () != Unzip.OK) {
            throw broken ();
        }
        var text = new StringBuilder ();
        var buffer = new uint8[65536];
        int count;
        while ((count = archive.read_current_file (buffer)) > 0) {
            text.append_len ((string) buffer, count);
        }
        archive.close_current_file ();
        if (count < 0) {
            throw broken ();
        }
        return text.str;
    }

    private void parse (XmlParser parser, string xml) throws XlsxError {
        try {
            parser.parse (xml);
        } catch (MarkupError e) {
            throw broken ();
        }
    }

    private XlsxError broken () {
        return new XlsxError.FORMAT (@"«$name» повреждён или это не таблица Excel");
    }
}

// Разбор XML: наследник получает элементы уже без префикса
// пространства имён («x:row» → «row») и текст внутри них
private abstract class XmlParser {
    public void parse (string xml) throws MarkupError {
        MarkupParser parser = { on_start, on_end, on_text, null, null };
        var context = new MarkupParseContext (parser, 0, this, null);
        context.parse (xml, -1);
        context.end_parse ();
    }

    protected abstract void start (string name, string[] names, string[] values);

    protected virtual void end (string name) {
    }

    protected virtual void text (string text, size_t length) {
    }

    // Значение атрибута по имени без префикса (r:id → id); null — атрибута нет
    protected static string? attribute (string[] names, string[] values, string name) {
        for (int i = 0; names[i] != null; i++) {
            if (local_name (names[i]) == name) {
                return values[i];
            }
        }
        return null;
    }

    private static string local_name (string name) {
        return name.substring (name.index_of_char (':') + 1);
    }

    private void on_start (MarkupParseContext context, string name, string[] names, string[] values) throws MarkupError {
        start (local_name (name), names, values);
    }

    private void on_end (MarkupParseContext context, string name) throws MarkupError {
        end (local_name (name));
    }

    private void on_text (MarkupParseContext context, string text, size_t length) throws MarkupError {
        this.text (text, length);
    }
}

// xl/workbook.xml: <sheet name="Лист1" sheetId="1" r:id="rId1"/>
private class WorkbookParser : XmlParser {
    public string? first_sheet_id = null;

    protected override void start (string name, string[] names, string[] values) {
        if (name == "sheet" && first_sheet_id == null) {
            first_sheet_id = attribute (names, values, "id");
        }
    }
}

// xl/_rels/workbook.xml.rels: <Relationship Id="rId1" Target="worksheets/sheet1.xml"/>
private class RelationsParser : XmlParser {
    public HashTable<string, string> targets = new HashTable<string, string> (str_hash, str_equal);

    protected override void start (string name, string[] names, string[] values) {
        var id = attribute (names, values, "Id");
        var target = attribute (names, values, "Target");
        if (name == "Relationship" && id != null && target != null) {
            targets[id] = target;
        }
    }
}

// xl/sharedStrings.xml: <si> — одна строка; её текст — во всех <t>,
// кроме фонетических подсказок <rPh> (японский текст)
private class SharedStringsParser : XmlParser {
    public GenericArray<string> strings = new GenericArray<string> ();
    private StringBuilder? current = null;
    private bool in_text = false;
    private int phonetic = 0;

    protected override void start (string name, string[] names, string[] values) {
        switch (name) {
        case "si":
            current = new StringBuilder ();
            break;
        case "t":
            in_text = current != null && phonetic == 0;
            break;
        case "rPh":
            phonetic++;
            break;
        }
    }

    protected override void end (string name) {
        switch (name) {
        case "si":
            strings.add (current.str);
            current = null;
            break;
        case "t":
            in_text = false;
            break;
        case "rPh":
            phonetic--;
            break;
        }
    }

    protected override void text (string text, size_t length) {
        if (in_text) {
            current.append_len (text, (ssize_t) length);
        }
    }
}

// Лист: <row r="1"><c r="A1" t="s"><v>0</v></c>…</row>. Тип ячейки t:
// «s» — номер общей строки, «inlineStr» — текст в <is><t>, «b» — 0 или 1,
// без t — число как его записал Excel (точка — разделитель дробной части)
private class SheetParser : XmlParser {
    public GenericArray<SheetRow> rows = new GenericArray<SheetRow> ();
    private GenericArray<string> shared;
    private SheetRow? row = null;
    private string[] cells = {};  // ячейки текущей строки
    private int column = 0;  // столбец текущей ячейки, с 0
    private string type = "";
    private StringBuilder? value = null;  // текст <v> или <is><t>
    private bool in_value = false;

    public SheetParser (GenericArray<string> shared) {
        this.shared = shared;
    }

    protected override void start (string name, string[] names, string[] values) {
        switch (name) {
        case "row":
            // Номер строки обычно записан; если нет — следующая за предыдущей
            var number = attribute (names, values, "r");
            row = new SheetRow () {
                number = number != null ? int.parse (number) : (rows.length > 0 ? rows[rows.length - 1].number + 1 : 1)
            };
            cells = {};
            column = 0;
            break;
        case "c":
            var reference = attribute (names, values, "r");
            if (reference != null) {
                column = column_index (reference);
            }
            type = attribute (names, values, "t") ?? "";
            value = new StringBuilder ();
            break;
        case "v":
        case "t":
            in_value = value != null;
            break;
        }
    }

    protected override void end (string name) {
        switch (name) {
        case "v":
        case "t":
            in_value = false;
            break;
        case "c":
            if (row != null && value != null) {
                while (cells.length <= column) {
                    cells += "";
                }
                cells[column] = cell_text (value.str);
            }
            value = null;
            column++;
            break;
        case "row":
            if (row != null) {
                row.cells = cells;
                rows.add (row);
            }
            row = null;
            break;
        }
    }

    protected override void text (string text, size_t length) {
        if (in_value) {
            value.append_len (text, (ssize_t) length);
        }
    }

    private string cell_text (string raw) {
        switch (type) {
        case "s":
            var index = int.parse (raw);
            return index >= 0 && index < shared.length ? shared[index] : "";
        case "b":
            return raw == "1" ? "ИСТИНА" : "ЛОЖЬ";
        default:
            return raw;
        }
    }

    // «A1» → 0, «B7» → 1, «AA3» → 26
    private static int column_index (string reference) {
        int index = 0;
        for (int i = 0; i < reference.length && reference[i].isalpha (); i++) {
            index = index * 26 + (reference[i].toupper () - 'A' + 1);
        }
        return int.max (index - 1, 0);
    }
}
