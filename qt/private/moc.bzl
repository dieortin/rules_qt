"""Rules that allow to use [Qt's moc](https://doc.qt.io/qt-5/moc.html) with Bazel."""

load(":private/utils.bzl", "MocInfo", "QT_TOOLCHAIN")

def _moc_hdrs_impl(ctx):
    toolchain = ctx.toolchains[QT_TOOLCHAIN]

    compilation_context = toolchain.qtinfo.headers[CcInfo].compilation_context

    cpps = list()
    jsons = list()
    for hdr in ctx.files.hdrs:
        moc = ctx.actions.declare_file("moc_{name}".format(name = hdr.basename.rstrip("." + hdr.extension)))

        json = ctx.actions.declare_file("{name}.json".format(name = moc.basename))
        jsons.append(json)

        args = ctx.actions.args()
        args.add("--output-json")
        #args.add("--debug-includes") # very useful for debugging

        for include_dir in compilation_context.system_includes.to_list():
            args.add("-I", include_dir)

        args.add(hdr)
        args.add("-o", moc)

        ctx.actions.run(
            inputs = ctx.files.hdrs + compilation_context.headers.to_list(),  # make all headers visible to moc
            outputs = [moc, json],
            progress_message = "[Qt moc]: generating {path}".format(path = moc.short_path),
            executable = toolchain.qtinfo.moc,
            arguments = [args],
        )

        # we need to fixup angle brackes includes in generated files to quoted ones
        cpp = ctx.actions.declare_file("{name}.cpp".format(name = moc.basename))
        cpps.append(cpp)

        substitution_pairs = list()
        for hdr in ctx.files.hdrs:
            substitution_pairs.append(
                ("\"{old_name}\"".format(old_name = hdr.basename), ("\"{new_name}\"".format(new_name = hdr.short_path))),
            )

        ctx.actions.expand_template(template = moc, output = cpp, substitutions = dict(substitution_pairs))

    transitive = [depset(ctx.files.hdrs)]
    return [
        DefaultInfo(files = depset(cpps, transitive = transitive)),
        MocInfo(jsons = jsons, headers = ctx.files.hdrs),
    ]

moc_hdrs = rule(
    implementation = _moc_hdrs_impl,
    doc = """
Invokes `moc` on a given set of headers and exposes generated (`moc`'ed) C++ sources
to be further used in downstream `cc_*` rules.

Besides C++ sources, the rules exposes metatypes info in `json` format via [MocInfo](providers-docs.md#MocInfo).
These are required to properly register C++ QtQml types when using the [qt_qml_cc_module](#qt_qml_cc_module).

Supports both [Qt5](https://doc.qt.io/qt-5/qtqml-cppintegration-definetypes.html) and [Qt6](https://doc.qt.io/qt-6.4/qtqml-cppintegration-definetypes.html).
""",
    attrs = {
        "hdrs": attr.label_list(
            allow_files = [".h", ".hh", ".hpp", ".hxx"],
            mandatory = True,
            doc = """
A list of C++ headers that needs to be `moc`'ed.
""",
        ),
    },
    toolchains = [QT_TOOLCHAIN],
    provides = [DefaultInfo, MocInfo],
)

def _moc_srcs_impl(ctx):
    toolchain = ctx.toolchains[QT_TOOLCHAIN]

    cpps = list()
    includes = list()
    for src in ctx.files.srcs:
        cpp = ctx.actions.declare_file("{name}".format(name = src.basename.replace(src.extension, "moc")))
        cpps.append(cpp)
        includes.append(cpp.dirname)

        args = ctx.actions.args()
        args.add("-o", cpp)
        args.add("-i")  # https://doc.qt.io/qt-5/moc.html#command-line-options
        args.add(src)

        ctx.actions.run(
            inputs = [src],
            outputs = [cpp],
            progress_message = "[Qt moc]: generating {path}".format(path = cpp.short_path),
            executable = toolchain.qtinfo.moc,
            arguments = [args],
        )

    compilation_context = cc_common.create_compilation_context(
        includes = depset(includes),
        headers = depset(cpps),
    )

    # Since, cc_* rules accept C++ files only with limited set of extensions,
    # but Qt requres to use .moc extension in some cases (see -i option above).
    # We use CcInfo to make both Bazel and Qt happy.
    # Other rules must depend on this rule via `deps`.
    # Additionally, we need to fill `includes` to keep compatibility with Qt
    # on how autogenerated files get included:
    # - Qt uses quote include style relative to current folder
    # - while Bazel requires to be more explicit with include paths
    #   and uses full paths relative to a project's root (WORKSPACE).
    return [CcInfo(compilation_context = compilation_context)]

moc_srcs = rule(
    implementation = _moc_srcs_impl,
    doc = """
Invokes `moc` on a given set of sources and exposes generated (`moc`'ed) C++ sources
to be further used in downstream `cc_*` rules.

See https://doc.qt.io/qt-5/moc.html#writing-make-rules-for-invoking-moc for more details.

The quote from the official docs:
```
For Q_OBJECT class declarations in implementation (.cpp) files, we suggest a makefile rule like this:

foo.o: foo.moc

foo.moc: foo.cpp
        moc $(DEFINES) $(INCPATH) -i $< -o $@

This guarantees that make will run the moc before it compiles foo.cpp. You can then put

#include "foo.moc"

at the end of foo.cpp, where all the classes declared in that file are fully known.
```

## NOTE

The rule uses `CcInfo` with `compilation_context` filled in to propagate `[generated_name].moc` (which is an implementation C++ file),
because `cc_*`'s `srcs` attribute has a fixed set of supported file extensions.
""",
    attrs = {
        "srcs": attr.label_list(
            allow_files = [".cc", ".cpp", ".cxx", ".c++"],
            mandatory = True,
            doc = """
A list of C++ sources that needs to be `moc`'ed.
""",
        ),
    },
    toolchains = [QT_TOOLCHAIN],
    provides = [CcInfo],
)
