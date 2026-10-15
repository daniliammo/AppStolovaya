// Привязка к libxlsxwriter (libxlsxwriter-dev): только то, что нужно экспорту.
// Документация C API: https://libxlsxwriter.github.io/

[CCode (cheader_filename = "xlsxwriter.h")]
namespace Xlsx {
    [CCode (cname = "lxw_error", cprefix = "LXW_", has_type_id = false)]
    public enum Error {
        NO_ERROR;

        [CCode (cname = "lxw_strerror")]
        public unowned string to_string ();
    }

    [CCode (cname = "uint8_t", cprefix = "LXW_ALIGN_", has_type_id = false)]
    public enum Align {
        NONE,
        LEFT,
        CENTER,
        RIGHT
    }

    [CCode (cname = "uint8_t", cprefix = "LXW_BORDER_", has_type_id = false)]
    public enum Border {
        NONE,
        THIN
    }

    // Книга освобождается внутри workbook_close (), поэтому free_function пустая:
    // close () нужно вызвать обязательно, ровно один раз.
    [Compact]
    [CCode (cname = "lxw_workbook", free_function = "")]
    public class Workbook {
        // null, если файл не удалось создать
        [CCode (cname = "workbook_new")]
        public static Workbook? create (string filename);

        [CCode (cname = "workbook_add_worksheet")]
        public unowned Worksheet? add_worksheet (string? name);

        [CCode (cname = "workbook_add_format")]
        public unowned Format add_format ();

        [CCode (cname = "workbook_close")]
        public Error close ();
    }

    [Compact]
    [CCode (cname = "lxw_worksheet", free_function = "")]
    public class Worksheet {
        [CCode (cname = "worksheet_write_string")]
        public Error write_string (uint32 row, uint16 col, string text, Format? format = null);

        [CCode (cname = "worksheet_write_number")]
        public Error write_number (uint32 row, uint16 col, double number, Format? format = null);

        [CCode (cname = "worksheet_set_column")]
        public Error set_column (uint16 first_col, uint16 last_col, double width, Format? format = null);

        [CCode (cname = "worksheet_freeze_panes")]
        public void freeze_panes (uint32 row, uint16 col);

        // При печати вписать в width страниц по ширине и height по высоте (0 — сколько нужно)
        [CCode (cname = "worksheet_fit_to_pages")]
        public void fit_to_pages (uint16 width, uint16 height);

        // Лист, открытый при открытии файла
        [CCode (cname = "worksheet_activate")]
        public void activate ();
    }

    [Compact]
    [CCode (cname = "lxw_format", free_function = "")]
    public class Format {
        [CCode (cname = "format_set_bold")]
        public void set_bold ();

        [CCode (cname = "format_set_align")]
        public void set_align (Align align);

        // Цвет 0xRRGGBB
        [CCode (cname = "format_set_bg_color")]
        public void set_bg_color (uint32 color);

        [CCode (cname = "format_set_top")]
        public void set_top (Border style);

        [CCode (cname = "format_set_bottom")]
        public void set_bottom (Border style);
    }
}
