public enum ReaderState {
    DISCONNECTED,  // считыватель не подключён
    NO_ACCESS,     // подключён, но нет прав на порт (нужна настройка системы)
    UNAVAILABLE,   // подключён, но порт не открывается (занят другой программой и т. п.)
    CONNECTED
}
