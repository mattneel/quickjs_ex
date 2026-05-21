[
  %{
    label: "QuickJS-NG C snapshot",
    name: :quickjs_ng,
    repo: "https://github.com/quickjs-ng/quickjs.git",
    files: [
      "builtin-array-fromasync.h",
      "builtin-iterator-zip-keyed.h",
      "builtin-iterator-zip.h",
      "cutils.h",
      "dtoa.c",
      "dtoa.h",
      "libregexp-opcode.h",
      "libregexp.c",
      "libregexp.h",
      "libunicode-table.h",
      "libunicode.c",
      "libunicode.h",
      "list.h",
      "quickjs-atom.h",
      "quickjs-c-atomics.h",
      "quickjs-libc.h",
      "quickjs-opcode.h",
      "quickjs.c",
      "quickjs.h",
      "unicode_gen_def.h"
    ],
    commit: "433941b99fb3c5e7f98b7ebd78727972bcf467ee",
    upstream: "quickjs-ng/quickjs",
    header_style: :c_block,
    source_dir: ".",
    target_dir: "c_src/quickjs_ng",
    local_files: [],
    replacements: []
  },
  %{
    label: "zig-quickjs-ng bindings",
    name: :zig_quickjs_ng,
    repo: "https://github.com/mitchellh/zig-quickjs-ng.git",
    files: [
      "atom.zig",
      "cfunc.zig",
      "class.zig",
      "context.zig",
      "main.zig",
      "module.zig",
      "opaque.zig",
      "runtime.zig",
      "typed_array.zig",
      "value.zig"
    ],
    commit: "eb1d44ce43fd64f8403c1a94fad242ebae04d1fb",
    upstream: "mitchellh/zig-quickjs-ng",
    header_style: :line_comment,
    source_dir: "src",
    target_dir: "priv/zig/zig_quickjs_ng",
    local_files: ["quickjs_c.zig"],
    replacements: [
      {"const c = @import(\"quickjs_c\");", "const c = @import(\"quickjs_c\").c;"},
      {"pub const c = @import(\"quickjs_c\");", "pub const c = @import(\"quickjs_c\").c;"}
    ]
  }
]
