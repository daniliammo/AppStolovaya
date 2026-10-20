// Какие программы держат файл открытым: процессы этого пользователя, у которых
// в /proc/<pid>/fd есть ссылка на файл. Так видно LibreOffice — он держит
// документ открытым всё время, пока тот открыт в окне. Программы, которые
// прочитали файл и сразу закрыли его, так не найти.
//
// Выгрузка заменяет файл новым (rename), а программа держит старый —
// ссылка на него выглядит как «путь (deleted)», такие тоже считаются.

public class FileUser {
    public int pid;
    public string name;  // для человека: «LibreOffice», иначе имя процесса
    public string path;  // какой из искомых файлов держит
}

namespace FileUsers {
    public GenericArray<FileUser> find (string path) {
        return find_all ({ path });
    }

    // Все, кто держит какой-нибудь из файлов, за один проход по /proc
    // (около 10 мс). Программа, держащая два файла, — два элемента.
    public GenericArray<FileUser> find_all (string[] paths) {
        var result = new GenericArray<FileUser> ();
        // Как файл выглядит в /proc → путь, как его передали. В /proc пути
        // без символических ссылок: ~/Документы может быть ссылкой.
        var targets = new HashTable<string, string> (str_hash, str_equal);
        foreach (var path in paths) {
            var dir = Posix.realpath (Path.get_dirname (path));
            if (dir != null) {
                var real_path = Path.build_filename (dir, Path.get_basename (path));
                targets[real_path] = path;
                targets[real_path + " (deleted)"] = path;
            }
        }
        if (targets.size () == 0) {
            return result;
        }

        Dir proc;
        try {
            proc = Dir.open ("/proc");
        } catch (FileError e) {
            return result;
        }
        var self = (int) Posix.getpid ();
        string? entry;
        while ((entry = proc.read_name ()) != null) {
            int pid;
            if (!int.try_parse (entry, out pid) || pid == self) {
                continue;
            }
            foreach (var path in held_files (pid, targets)) {
                result.add (new FileUser () { pid = pid, name = program_name (pid), path = path });
            }
        }
        return result;
    }

    // Попросить программу закрыться (SIGTERM), как при выключении компьютера.
    // false — сигнал не отправлен (процесса уже нет).
    public bool terminate (FileUser user) {
        return Posix.kill (user.pid, Posix.Signal.TERM) == 0;
    }

    // LibreOffice, закрытый сигналом, оставляет файл блокировки «.~lock.имя#»
    // и при следующем открытии сообщает, что файл занят. Убрать его, если
    // файл больше никто не держит.
    public void remove_stale_lock (string path) {
        if (find (path).length == 0) {
            FileUtils.remove (Path.build_filename (Path.get_dirname (path),
                ".~lock." + Path.get_basename (path) + "#"));
        }
    }

    // Какие из искомых файлов процесс держит открытыми, без повторов
    private string[] held_files (int pid, HashTable<string, string> targets) {
        string[] result = {};
        var fd_dir = "/proc/%d/fd".printf (pid);
        Dir fds;
        try {
            fds = Dir.open (fd_dir);
        } catch (FileError e) {
            return result;  // процесс другого пользователя или уже завершился
        }
        string? fd;
        while ((fd = fds.read_name ()) != null) {
            try {
                var path = targets[FileUtils.read_link (Path.build_filename (fd_dir, fd))];
                if (path != null && !(path in result)) {
                    result += path;
                }
            } catch (FileError e) {
                // Дескриптор успели закрыть
            }
        }
        return result;
    }

    private string program_name (int pid) {
        string comm = "";
        try {
            FileUtils.get_contents ("/proc/%d/comm".printf (pid), out comm);
        } catch (FileError e) {
            // Процесс успел завершиться
        }
        comm = comm.strip ();
        switch (comm) {
        case "soffice.bin":
            return "LibreOffice";
        case "":
            return "процесс %d".printf (pid);
        default:
            return comm;
        }
    }
}
