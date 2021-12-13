load("@bazel_skylib//lib:shell.bzl", "shell")
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
load(":zig_toolchain.bzl", "zig_cc_toolchain_config")

DEFAULT_TOOL_PATHS = {
    "ar": "ar",
    "gcc": "c++",  # https://github.com/bazelbuild/bazel/issues/4644
    "cpp": "/usr/bin/false",
    "gcov": "/usr/bin/false",
    "nm": "/usr/bin/false",
    "objdump": "/usr/bin/false",
    "strip": "/usr/bin/false",
}.items()

DEFAULT_INCLUDE_DIRECTORIES = [
    "include",
    "libcxx/include",
    "libcxxabi/include",
]

_fcntl_map = """
GLIBC_2.2.5 {
   fcntl;
};
"""
_fcntl_h = """
#ifdef __ASSEMBLER__
.symver fcntl64, fcntl@GLIBC_2.2.5
#else
__asm__(".symver fcntl64, fcntl@GLIBC_2.2.5");
#endif
"""

# Zig supports even older glibcs than defined below, but we have tested only
# down to 2.17.
# $ zig targets | jq -r '.glibc[]' | sort -V
_GLIBCS = [
    "2.17",
    "2.18",
    "2.19",
    "2.22",
    "2.23",
    "2.24",
    "2.25",
    "2.26",
    "2.27",
    "2.28",
    "2.29",
    "2.30",
    "2.31",
    "2.32",
    "2.33",
]

def _target_darwin(gocpu, zigcpu):
    return struct(
        gotarget = "darwin_{}".format(gocpu),
        zigtarget = "{}-macos-gnu".format(zigcpu),
        includes = [
            "libunwind/include",
            # FIXME: add macos.10, macos.11 and macos.12 targets,
            # and adjust the includes
            "libc/include/{}-macos.10-gnu".format(zigcpu),
            "libc/include/{}-macos-any".format(zigcpu),
            "libc/include/any-macos-any",
        ],
        linkopts = [],
        copts = [],
        bazel_target_cpu = "darwin",
        constraint_values = [
            "@platforms//os:macos",
            "@platforms//cpu:{}".format(zigcpu),
        ],
        tool_paths = {"ld": "ld64.lld"},
    )

def _target_linux_gnu(gocpu, zigcpu, glibc_version = ""):
    glibc_suffix = "gnu"
    if glibc_version != "":
        glibc_suffix = "gnu.{}".format(glibc_version)

    # https://github.com/ziglang/zig/issues/5882#issuecomment-888250676
    # fcntl_hack is only required for glibc 2.27 or less. We assume that
    # glibc_version == "" (autodetect) is running a recent glibc version, thus
    # adding this hack only when glibc is explicitly 2.27 or lower.
    fcntl_hack = False
    if glibc_version == "":
        # zig doesn't reliably detect the glibc version, so
        # often falls back to 2.17; the hack should be included.
        # https://github.com/ziglang/zig/issues/6469
        fcntl_hack = True
    else:
        # hack is required for 2.27 or less.
        fcntl_hack = glibc_version < "2.28"

    return struct(
        gotarget = "linux_{}_{}".format(gocpu, glibc_suffix),
        zigtarget = "{}-linux-{}".format(zigcpu, glibc_suffix),
        includes = [
            "libunwind/include",
            "libc/include/generic-glibc",
            "libc/include/any-linux-any",
            "libc/include/{}-linux-gnu".format(zigcpu),
            "libc/include/{}-linux-any".format(zigcpu),
        ] + ["libc/include/x86-linux-any"] if zigcpu == "x86_64" else [],
        toplevel_include = ["glibc-hacks"] if fcntl_hack else [],
        compiler_extra_includes = ["glibc-hacks/glibchack-fcntl.h"] if fcntl_hack else [],
        linker_version_scripts = ["glibc-hacks/fcntl.map"] if fcntl_hack else [],
        linkopts = ["-lc++", "-lc++abi"],
        copts = [],
        bazel_target_cpu = "k8",
        constraint_values = [
            "@platforms//os:linux",
            "@platforms//cpu:{}".format(zigcpu),
        ],
        tool_paths = {"ld": "ld.lld"},
    )

def _target_linux_musl(gocpu, zigcpu):
    return struct(
        gotarget = "linux_{}_musl".format(gocpu),
        zigtarget = "{}-linux-musl".format(zigcpu),
        includes = [
            "libc/include/generic-musl",
            "libc/include/any-linux-any",
            "libc/include/{}-linux-musl".format(zigcpu),
            "libc/include/{}-linux-any".format(zigcpu),
        ] + ["libc/include/x86-linux-any"] if zigcpu == "x86_64" else [],
        linkopts = ["-s", "-w"],
        copts = ["-D_LIBCPP_HAS_MUSL_LIBC", "-D_LIBCPP_HAS_THREAD_API_PTHREAD"],
        bazel_target_cpu = "k8",
        constraint_values = [
            "@platforms//os:linux",
            "@platforms//cpu:{}".format(zigcpu),
        ],
        tool_paths = {"ld": "ld.lld"},
    )

# Nightly
_URL_FORMAT_RELEASE = "https://ziglang.org/download/{version}/zig-{host_platform}-{version}.tar.xz"
_URL_FORMAT_NIGHTLY = "https://ziglang.org/builds/zig-{host_platform}-{version}.tar.xz"
_URL_FORMAT_JAKSTYS = "https://dl.jakstys.lt/zig/zig-{host_platform}-{version}.tar.xz"

_VERSION = "0.9.0-dev.1950+a76910b69"

def register_toolchains(
        register = [],
        version = _VERSION,
        url_format = _URL_FORMAT_JAKSTYS,
        host_platform_sha256 = {}):
    """
        Download zig toolchain and register some.
        @param register registers the given toolchains to the system using
        native.register_toolchains(). See README for possible choices.
    """
    sha256s = {
        "linux-aarch64": "df2a1800f3960010e70956891abcb88cb9a559aedd54c0373ef706b439e8b9cb",
        "linux-x86_64": "a1410d2ad1a647f7033ab0109716434d233def438ff1b4e8b968d428e9e671fc",
        "macos-aarch64": "274c012149421511be700f28271ceaccb06d951f2ea9e6d805eef740d2a54634",
        "macos-x86_64": "9f49975b0926feadc709db774fd5cc026d32e2c21c09734c550e975b8db95c56",
    }
    sha256s.update(host_platform_sha256)

    zig_repository(
        name = "zig_sdk",
        version = version,
        url_format = url_format,
        host_platform_sha256 = sha256s,
        host_platform_include_root = {
            "linux-aarch64": "lib/",
            "linux-x86_64": "lib/",
            "macos-aarch64": "lib/zig/",
            "macos-x86_64": "lib/zig/",
        },
    )

    toolchains = ["@zig_sdk//:%s_toolchain" % t for t in register]
    native.register_toolchains(*toolchains)

ZIG_TOOL_PATH = "tools/{zig_tool}"
ZIG_TOOL_WRAPPER = """#!/bin/bash
set -e

if [[ -n "$TMPDIR" ]]; then
  _cache_prefix=$TMPDIR
else
  _cache_prefix="$HOME/.cache"
  if [[ "$(uname)" = Darwin ]]; then
    _cache_prefix="$HOME/Library/Caches"
  fi
fi
export ZIG_LOCAL_CACHE_DIR="$_cache_prefix/bazel-zig-cc"
export ZIG_GLOBAL_CACHE_DIR=$ZIG_LOCAL_CACHE_DIR

exec "{zig}" "{zig_tool}" "$@"
"""

_ZIG_TOOLS = [
    "c++",
    "cc",
    "ar",
    "ld.lld",  # ELF
    "ld64.lld",  # Mach-O
    "lld-link",  # COFF
    "wasm-ld",  # WebAssembly
]

def _zig_repository_impl(repository_ctx):
    res = repository_ctx.execute(["uname", "-m"])
    if res.return_code != 0:
        fail("failed to run uname -m")
    uname = res.stdout.strip()

    if repository_ctx.os.name.lower().startswith("mac os"):
        host_platform = "macos-{}".format(uname)
    else:
        host_platform = "linux-{}".format(uname)

    zig_include_root = repository_ctx.attr.host_platform_include_root[host_platform]
    zig_sha256 = repository_ctx.attr.host_platform_sha256[host_platform]
    format_vars = {
        "version": repository_ctx.attr.version,
        "host_platform": host_platform,
    }
    zig_url = repository_ctx.attr.url_format.format(**format_vars)

    repository_ctx.download_and_extract(
        url = zig_url,
        stripPrefix = "zig-{host_platform}-{version}/".format(**format_vars),
        sha256 = zig_sha256,
    )

    for zig_tool in _ZIG_TOOLS:
        repository_ctx.file(
            ZIG_TOOL_PATH.format(zig_tool = zig_tool),
            ZIG_TOOL_WRAPPER.format(
                zig = str(repository_ctx.path("zig")),
                zig_tool = zig_tool,
            ),
        )

    repository_ctx.file(
        "glibc-hacks/fcntl.map",
        content = _fcntl_map,
    )
    repository_ctx.file(
        "glibc-hacks/glibchack-fcntl.h",
        content = _fcntl_h,
    )

    repository_ctx.template(
        "BUILD.bazel",
        Label("//toolchain:BUILD.sdk.bazel"),
        executable = False,
        substitutions = {
            "{absolute_path}": shell.quote(str(repository_ctx.path(""))),
            "{zig_include_root}": shell.quote(zig_include_root),
        },
    )

zig_repository = repository_rule(
    attrs = {
        "version": attr.string(),
        "host_platform_sha256": attr.string_dict(),
        "url_format": attr.string(),
        "host_platform_include_root": attr.string_dict(),
    },
    implementation = _zig_repository_impl,
)

def _target_structs():
    ret = []
    for zigcpu, gocpu in (("x86_64", "amd64"), ("aarch64", "arm64")):
        ret.append(_target_darwin(gocpu, zigcpu))
        ret.append(_target_linux_musl(gocpu, zigcpu))
        for glibc in [""] + _GLIBCS:
            ret.append(_target_linux_gnu(gocpu, zigcpu, glibc))
    return ret

def filegroup(name, **kwargs):
    native.filegroup(name = name, **kwargs)
    return ":" + name

def zig_build_macro(absolute_path, zig_include_root):
    filegroup(name = "empty")
    native.exports_files(["zig"], visibility = ["//visibility:public"])
    filegroup(name = "lib/std", srcs = native.glob(["lib/std/**"]))

    lazy_filegroups = {}

    for target_config in _target_structs():
        gotarget = target_config.gotarget
        zigtarget = target_config.zigtarget

        cxx_builtin_include_directories = []
        for d in DEFAULT_INCLUDE_DIRECTORIES + target_config.includes:
            d = zig_include_root + d
            if d not in lazy_filegroups:
                lazy_filegroups[d] = filegroup(name = d, srcs = native.glob([d + "/**"]))
            cxx_builtin_include_directories.append(absolute_path + "/" + d)
        for d in getattr(target_config, "toplevel_include", []):
            cxx_builtin_include_directories.append(absolute_path + "/" + d)

        absolute_tool_paths = {}
        for name, path in target_config.tool_paths.items() + DEFAULT_TOOL_PATHS:
            if path[0] == "/":
                absolute_tool_paths[name] = path
                continue
            tool_path = ZIG_TOOL_PATH.format(zig_tool = path)
            absolute_tool_paths[name] = "%s/%s" % (absolute_path, tool_path)

        linkopts = target_config.linkopts
        copts = target_config.copts
        for s in getattr(target_config, "linker_version_scripts", []):
            linkopts = linkopts + ["-Wl,--version-script,%s/%s" % (absolute_path, s)]
        for incl in getattr(target_config, "compiler_extra_includes", []):
            copts = copts + ["-include", absolute_path + "/" + incl]

        zig_cc_toolchain_config(
            name = zigtarget + "_toolchain_cc_config",
            target = zigtarget,
            tool_paths = absolute_tool_paths,
            cxx_builtin_include_directories = cxx_builtin_include_directories,
            copts = copts,
            linkopts = linkopts,
            target_cpu = target_config.bazel_target_cpu,
            target_system_name = "unknown",
            target_libc = "unknown",
            compiler = "clang",
            abi_version = "unknown",
            abi_libc_version = "unknown",
        )

        native.cc_toolchain(
            name = zigtarget + "_toolchain_cc",
            toolchain_identifier = zigtarget + "-toolchain",
            toolchain_config = ":%s_toolchain_cc_config" % zigtarget,
            all_files = ":zig",
            ar_files = ":zig",
            compiler_files = ":zig",
            linker_files = ":zig",
            dwp_files = ":empty",
            objcopy_files = ":empty",
            strip_files = ":empty",
            supports_param_files = 0,
        )

        # register two kinds of toolchain targets: Go and Zig conventions.
        # Go convention: amd64/arm64, linux/darwin
        native.toolchain(
            name = gotarget + "_toolchain",
            exec_compatible_with = None,
            target_compatible_with = target_config.constraint_values,
            toolchain = ":%s_toolchain_cc" % zigtarget,
            toolchain_type = "@bazel_tools//tools/cpp:toolchain_type",
        )

        # Zig convention: x86_64/aarch64, linux/macos
        native.toolchain(
            name = zigtarget + "_toolchain",
            exec_compatible_with = None,
            target_compatible_with = target_config.constraint_values,
            toolchain = ":%s_toolchain_cc" % zigtarget,
            toolchain_type = "@bazel_tools//tools/cpp:toolchain_type",
        )
