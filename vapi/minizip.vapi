// Привязка к minizip (libminizip-dev): только чтение файлов из zip-архива.
// minizip уже нужен libxlsxwriter, так что новой зависимости у программы нет.

[CCode (cheader_filename = "unzip.h")]
namespace Unzip {
    [CCode (cname = "UNZ_OK")]
    public const int OK;

    // unzFile — это void*
    [Compact]
    [CCode (cname = "void", free_function = "unzClose")]
    public class Archive {
        [CCode (cname = "unzOpen64")]
        public static Archive? open (string path);

        // Сделать файл архива текущим. case_sensitivity: 1 — с учётом регистра.
        [CCode (cname = "unzLocateFile")]
        public int locate_file (string name, int case_sensitivity);

        [CCode (cname = "unzOpenCurrentFile")]
        public int open_current_file ();

        // Сколько байт прочитано; 0 — конец файла, меньше нуля — ошибка
        [CCode (cname = "unzReadCurrentFile")]
        public int read_current_file ([CCode (array_length_type = "unsigned int")] uint8[] buffer);

        [CCode (cname = "unzCloseCurrentFile")]
        public int close_current_file ();
    }
}
