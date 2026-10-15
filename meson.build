project('hello-gtk4', 'vala', 'c',
  version: '0.1.0',
  meson_version: '>= 0.62.0',
)

gnome = import('gnome')

# Интерфейс (data/*.ui) встраивается в бинарник как GResource
resources = gnome.compile_resources('resources',
  'data/hello.gresource.xml',
  source_dir: 'data',
  c_name: 'resources',
)

executable('hello-gtk4',
  'src/main.vala',
  'src/window.vala',
  resources,
  dependencies: [
    dependency('glib-2.0'),
    dependency('gobject-2.0'),
    dependency('gtk4'),
    dependency('libadwaita-1', version: '>= 1.5'),
  ],
  install: true,
)
