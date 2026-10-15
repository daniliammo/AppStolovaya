project('hello-gtk4', 'vala', 'c',
  version: '0.1.0',
  meson_version: '>= 0.62.0',
)

executable('hello-gtk4',
  'src/main.vala',
  'src/main_window_ui.vala',
  'src/window.vala',
  dependencies: [
    dependency('glib-2.0'),
    dependency('gobject-2.0'),
    dependency('gtk4'),
    dependency('libadwaita-1', version: '>= 1.5'),
  ],
  install: true,
)
