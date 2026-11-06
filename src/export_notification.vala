// Помощник без окон: остаётся на шине после выхода приложения, пока
// пользователь не нажмёт на уведомление или не закроет его.
namespace ExportNotification {
    public const string FLAG = "--export-notification";

    public int run (string title, string body, string[] files) {
        try {
            var bus = Bus.get_sync (BusType.SESSION);
            var loop = new MainLoop ();
            uint32 id = 0;
            string? token = null;
            var subscription = bus.signal_subscribe (
                "org.freedesktop.Notifications", "org.freedesktop.Notifications",
                null, "/org/freedesktop/Notifications", null, DBusSignalFlags.NONE,
                (connection, sender, path, iface, name, parameters) => {
                    if (id == 0 || parameters.get_child_value (0).get_uint32 () != id) {
                        return;
                    }
                    switch (name) {
                    case "ActivationToken":
                        token = parameters.get_child_value (1).get_string ();
                        break;
                    case "ActionInvoked":
                        var action = parameters.get_child_value (1).get_string ();
                        if (action == "default" || action == "open-folder") {
                            show_in_file_manager (files, token);
                            loop.quit ();
                        }
                        break;
                    case "NotificationClosed":
                        loop.quit ();
                        break;
                    }
                });
            string[] actions = files.length > 0
                ? new string[] { "default", "Открыть папку", "open-folder", "Открыть папку" }
                : new string[0];
            // Без desktop-entry: GNOME иначе удалит уведомление при выходе
            // основного приложения. Помощник не создаёт окна.
            var reply = bus.call_sync (
                "org.freedesktop.Notifications", "/org/freedesktop/Notifications",
                "org.freedesktop.Notifications", "Notify",
                new Variant ("(susss@as@a{sv}i)", "Столовая", 0u,
                    "x-office-spreadsheet", title, body, new Variant.strv (actions),
                    new Variant.array (VariantType.VARDICT.element (), {}), -1),
                new VariantType ("(u)"), DBusCallFlags.NONE, 2000);
            id = reply.get_child_value (0).get_uint32 ();
            if (files.length > 0 && id != 0) {
                loop.run ();
            }
            bus.signal_unsubscribe (subscription);
            return 0;
        } catch (Error e) {
            warning ("Уведомление после выхода: %s", e.message);
            return 1;
        }
    }
    // Открыть папку с файлами в файловом менеджере и выделить их.
    // Не умеет (нет org.freedesktop.FileManager1) — просто открыть папку.
    public static void show_in_file_manager (string[] files, string? token) {
        if (files.length == 0) {
            return;
        }
        var uris = new string[0];
        foreach (var file in files) {
            uris += File.new_for_path (file).get_uri ();
        }
        try {
            Bus.get_sync (BusType.SESSION).call_sync (
                "org.freedesktop.FileManager1", "/org/freedesktop/FileManager1",
                "org.freedesktop.FileManager1", "ShowItems",
                new Variant.tuple ({ new Variant.strv (uris), new Variant.string (token ?? "") }),
                null, DBusCallFlags.NONE, 5000);
            return;
        } catch (Error e) {
            debug ("FileManager1.ShowItems: %s", e.message);
        }
        try {
            var folder = File.new_for_path (files[0]).get_parent ();
            AppInfo.launch_default_for_uri (folder.get_uri (), null);
        } catch (Error e) {
            warning ("Не удалось открыть папку: %s", e.message);
        }
    }

}
