// Картинка для уведомления о карточке: круг с инициалами ученика, как
// Adw.Avatar в окне, или с карточкой и «?», если карточка не зарегистрирована.
// Рисуем сами через Cairo: Adw.Avatar.draw_to_texture () нужен показанный
// на экране виджет, а уведомление шлём, когда окно свёрнуто.
// Отдаём подсказкой image-data уведомлений freedesktop.

namespace NotificationAvatar {
    const int SIZE = 128;

    // Цвета Adw.Avatar (avatar.color1…color14 в стиле libadwaita):
    // верх и низ градиента фона, цвет букв
    const string[] COLORS = {
        "#83b6ec", "#337fdc", "#cfe1f5",
        "#7ad9f1", "#0f9ac8", "#caeaf2",
        "#8de6b1", "#29ae74", "#cef8d8",
        "#b5e98a", "#6ab85b", "#e6f9d7",
        "#f8e359", "#d29d09", "#f9f4e1",
        "#ffcb62", "#d68400", "#ffead1",
        "#ffa95a", "#ed5b00", "#ffe5c5",
        "#f78773", "#e62d42", "#f8d2ce",
        "#e973ab", "#e33b6a", "#fac7de",
        "#cb78d4", "#9945b5", "#e7c2e8",
        "#9e91e8", "#7a59ca", "#d5d2f5",
        "#e3cf9c", "#b08952", "#f2eade",
        "#be916d", "#785336", "#e5d6ca",
        "#c0bfbc", "#6e6d71", "#d8d7d3",
    };
    // Незарегистрированная карточка — оранжевым, как жёлтый экран в окне
    const int UNKNOWN_COLOR = 5;

    public Variant student (string full_name) {
        // Как Adw.Avatar: цвет по хешу имени — в окне и в уведомлении один и тот же
        var color = (int) (str_hash (full_name) % (COLORS.length / 3));
        Cairo.ImageSurface surface;
        var cr = background (color, out surface);
        draw_text (cr, initials (full_name), SIZE * 0.4);
        return image_data (surface);
    }

    public Variant unknown_card () {
        Cairo.ImageSurface surface;
        var cr = background (UNKNOWN_COLOR, out surface);
        // Карточка — скруглённый прямоугольник, на ней «?»
        double w = SIZE * 0.56, h = SIZE * 0.38, r = SIZE * 0.06;
        double x = (SIZE - w) / 2, y = (SIZE - h) / 2;
        cr.new_sub_path ();
        cr.arc (x + w - r, y + r, r, -Math.PI / 2, 0);
        cr.arc (x + w - r, y + h - r, r, 0, Math.PI / 2);
        cr.arc (x + r, y + h - r, r, Math.PI / 2, Math.PI);
        cr.arc (x + r, y + r, r, Math.PI, 3 * Math.PI / 2);
        cr.close_path ();
        cr.set_line_width (SIZE * 0.045);
        cr.stroke ();
        draw_text (cr, "?", SIZE * 0.3);
        return image_data (surface);
    }

    // Инициалы как у Adw.Avatar: первая буква имени и первая буква последнего слова
    public string initials (string full_name) {
        var text = full_name.strip ().up ().normalize ();
        if (text == "") {
            return "";
        }
        var result = text.get_char ().to_string ();
        var space = text.last_index_of_char (' ');
        if (space >= 0) {
            var last = text.offset (space + 1).get_char ();
            if (last != 0) {
                result += last.to_string ();
            }
        }
        return result;
    }

    // Круг с градиентом; дальше рисуем цветом букв
    Cairo.Context background (int color, out Cairo.ImageSurface surface) {
        surface = new Cairo.ImageSurface (Cairo.Format.ARGB32, SIZE, SIZE);
        var cr = new Cairo.Context (surface);
        var gradient = new Cairo.Pattern.linear (0, 0, 0, SIZE);
        add_stop (gradient, 0, COLORS[color * 3]);
        add_stop (gradient, 1, COLORS[color * 3 + 1]);
        cr.arc (SIZE / 2.0, SIZE / 2.0, SIZE / 2.0, 0, 2 * Math.PI);
        cr.set_source (gradient);
        cr.fill ();
        var rgba = Gdk.RGBA ();
        rgba.parse (COLORS[color * 3 + 2]);
        cr.set_source_rgb (rgba.red, rgba.green, rgba.blue);
        return cr;
    }

    void add_stop (Cairo.Pattern gradient, double offset, string color) {
        var rgba = Gdk.RGBA ();
        rgba.parse (color);
        gradient.add_color_stop_rgb (offset, rgba.red, rgba.green, rgba.blue);
    }

    // Текст жирным по центру круга
    void draw_text (Cairo.Context cr, string text, double font_size) {
        var layout = Pango.cairo_create_layout (cr);
        var font = new Pango.FontDescription ();
        font.set_family ("Sans");
        font.set_weight (Pango.Weight.BOLD);
        font.set_absolute_size (font_size * Pango.SCALE);
        layout.set_font_description (font);
        layout.set_text (text, -1);
        Pango.Rectangle ink;
        layout.get_pixel_extents (out ink, null);
        cr.move_to ((SIZE - ink.width) / 2.0 - ink.x, (SIZE - ink.height) / 2.0 - ink.y);
        Pango.cairo_show_layout (cr, layout);
    }

    // image-data — (iiibiiay): ширина, высота, шаг строки, есть ли альфа,
    // бит на канал, каналов, байты RGBA. В Cairo пиксель — число ARGB
    // с цветом, умноженным на альфу, — переводим.
    Variant image_data (Cairo.ImageSurface surface) {
        surface.flush ();
        unowned uint8[] src = surface.get_data ();
        var stride = surface.get_stride ();
        var rgba = new uint8[SIZE * SIZE * 4];
        for (int y = 0; y < SIZE; y++) {
            for (int x = 0; x < SIZE; x++) {
                var pixel = *((uint32*) (&src[y * stride + x * 4]));
                var a = (uint8) (pixel >> 24);
                var i = (y * SIZE + x) * 4;
                if (a != 0) {
                    rgba[i] = (uint8) ((((pixel >> 16) & 0xff) * 255 + a / 2) / a);
                    rgba[i + 1] = (uint8) ((((pixel >> 8) & 0xff) * 255 + a / 2) / a);
                    rgba[i + 2] = (uint8) (((pixel & 0xff) * 255 + a / 2) / a);
                }
                rgba[i + 3] = a;
            }
        }
        return new Variant ("(iiibii@ay)", SIZE, SIZE, SIZE * 4, true, 8, 4,
            new Variant.from_bytes (VariantType.BYTESTRING, new Bytes.take ((owned) rgba), true));
    }
}
