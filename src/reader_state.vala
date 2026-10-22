public enum ReaderState {
    DISCONNECTED,  // считыватель не подключён
    NO_ACCESS,     // подключён, но нет прав на порт (нужна настройка системы)
    CONNECTED
}
