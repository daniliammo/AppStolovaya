// Тесты поиска программ, держащих файл открытым. Запуск: meson test -C build

string tmp_dir;

// sleep, у которого файл открыт на дескрипторе 3 (как документ в LibreOffice)
Pid hold_open (string path) throws Error {
    Pid pid;
    Process.spawn_async (null, { "sh", "-c", "exec 3<\"$0\"; exec sleep 30", path }, null,
        SpawnFlags.SEARCH_PATH | SpawnFlags.DO_NOT_REAP_CHILD, null, out pid);
    // Подождать, пока sh откроет файл и сменится на sleep
    for (int i = 0; i < 100; i++) {
        var users = FileUsers.find (path);
        if (users.length == 1 && users[0].name == "sleep") {
            break;
        }
        Thread.usleep (20000);
    }
    return pid;
}

void test_find_and_terminate () throws Error {
    var path = Path.build_filename (tmp_dir, "столовая.xlsx");
    FileUtils.set_contents (path, "старый");
    assert_cmpint (FileUsers.find (path).length, CompareOperator.EQ, 0);

    var pid = hold_open (path);
    var users = FileUsers.find (path);
    assert_cmpint (users.length, CompareOperator.EQ, 1);
    assert_cmpint (users[0].pid, CompareOperator.EQ, (int) pid);
    assert_cmpstr (users[0].name, CompareOperator.EQ, "sleep");

    // Выгрузка заменила файл — программа держит старый, это тоже считается
    var tmp_path = path + ".tmp";
    FileUtils.set_contents (tmp_path, "новый");
    FileUtils.rename (tmp_path, path);
    assert_cmpint (FileUsers.find (path).length, CompareOperator.EQ, 1);

    // Блокировка LibreOffice остаётся, пока файл держат
    var lock_path = Path.build_filename (tmp_dir, ".~lock.столовая.xlsx#");
    FileUtils.set_contents (lock_path, "");
    FileUsers.remove_stale_lock (path);
    assert_true (FileUtils.test (lock_path, FileTest.EXISTS));

    assert_true (FileUsers.terminate (users[0]));
    int status;
    Posix.waitpid ((Posix.pid_t) pid, out status, 0);
    Process.close_pid (pid);
    assert_cmpint (FileUsers.find (path).length, CompareOperator.EQ, 0);

    FileUsers.remove_stale_lock (path);
    assert_false (FileUtils.test (lock_path, FileTest.EXISTS));
    FileUtils.remove (path);
}

// Папка — символическая ссылка (как бывает с ~/Документы): в /proc путь без неё
void test_symlinked_directory () throws Error {
    var real_dir = Path.build_filename (tmp_dir, "настоящая");
    var link_dir = Path.build_filename (tmp_dir, "ссылка");
    DirUtils.create (real_dir, 0755);
    FileUtils.symlink (real_dir, link_dir);
    var path = Path.build_filename (link_dir, "столовая.xlsx");
    FileUtils.set_contents (path, "");

    var pid = hold_open (path);
    var users = FileUsers.find (path);
    assert_cmpint (users.length, CompareOperator.EQ, 1);

    FileUsers.terminate (users[0]);
    int status;
    Posix.waitpid ((Posix.pid_t) pid, out status, 0);
    Process.close_pid (pid);

    FileUtils.remove (path);
    FileUtils.remove (link_dir);
    DirUtils.remove (real_dir);
}

void test_missing_directory () {
    assert_cmpint (FileUsers.find ("/нет/такой/папки/столовая.xlsx").length, CompareOperator.EQ, 0);
}

int main (string[] args) {
    Test.init (ref args);
    try {
        tmp_dir = DirUtils.make_tmp ("stolovaya-users-XXXXXX");
    } catch (FileError e) {
        error ("%s", e.message);
    }
    Test.add_func ("/file-users/find-and-terminate", () => wrap (test_find_and_terminate));
    Test.add_func ("/file-users/symlinked-directory", () => wrap (test_symlinked_directory));
    Test.add_func ("/file-users/missing-directory", test_missing_directory);
    var result = Test.run ();
    DirUtils.remove (tmp_dir);
    return result;
}

delegate void TestBody () throws Error;

void wrap (TestBody body) {
    try {
        body ();
    } catch (Error e) {
        error ("%s", e.message);
    }
}
