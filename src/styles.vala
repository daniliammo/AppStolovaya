// Стили главного окна. Подключаются один раз при запуске программы
// (HelloApp.startup). Цвета берутся из темы libadwaita, поэтому
// в светлой и тёмной теме карточки выглядят одинаково понятно.

namespace Styles {
    private const string CSS = """
        /* Большая карточка состояния */
        .status-card {
            border-radius: 24px;
            transition: background-color 250ms ease-out;
        }
        .status-card.status-ok {
            background-color: alpha(@success_color, 0.22);
        }
        .status-card.status-again {
            background-color: alpha(@error_color, 0.22);
        }
        .status-card.status-unknown {
            background-color: alpha(@warning_color, 0.35);
        }
        .status-card.status-ok .result-icon { color: @success_color; }
        .status-card.status-again .result-icon { color: @error_color; }
        .status-card.status-unknown .result-icon { color: @warning_color; }

        .result-title {
            font-size: 40px;
            font-weight: 800;
        }

        /* Часы на экране ожидания */
        .big-clock {
            font-size: 96px;
            font-weight: 800;
            font-feature-settings: "tnum";
        }

        /* Значок карточки «дышит», пока ждём */
        @keyframes breathe {
            from { opacity: 0.35; transform: scale(0.94); }
            to   { opacity: 0.85; transform: scale(1.04); }
        }
        .breathing {
            animation: breathe 1.6s ease-in-out infinite alternate;
        }

        .student-name {
            font-size: 36px;
            font-weight: 800;
        }

        /* Кнопки под сенсорный экран: основная — 120 px, остальные — не меньше 64 px */
        .meal-button {
            min-height: 120px;
            border-radius: 20px;
            font-size: 30px;
            font-weight: 800;
        }
        .touch-button {
            min-height: 64px;
            font-size: 18px;
            padding-left: 32px;
            padding-right: 32px;
        }

        /* Плашки счётчиков; текущий приём пищи подсвечен */
        .counter-tile {
            padding: 12px 18px;
        }
        .counter-tile.current {
            background-color: alpha(@accent_bg_color, 0.18);
            box-shadow: inset 0 0 0 2px @accent_color;
        }
        .counter-number {
            font-size: 40px;
            font-weight: 800;
        }
        .counter-tile progressbar trough,
        .counter-tile progressbar progress {
            min-height: 10px;
            border-radius: 5px;
        }
    """;

    public void load () {
        var provider = new Gtk.CssProvider ();
        provider.load_from_string (CSS);
        Gtk.StyleContext.add_provider_for_display (Gdk.Display.get_default (), provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
    }
}
