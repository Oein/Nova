const std = @import("std");

/// Kept in step with build.zig.zon; both end up in the bundle's Info.plist.
const version = "0.1.0";

/// SQLite build flags.
///
/// FTS5 is mandatory: note search runs through an `fts5(... tokenize='trigram')`
/// virtual table (see `db/schema.zig`), and without it the schema fails to
/// create. The rest trims features the app never uses.
const sqlite_flags = [_][]const u8{
    "-DSQLITE_ENABLE_FTS5",
    "-DSQLITE_THREADSAFE=1",
    "-DSQLITE_DEFAULT_MEMSTATUS=0",
    "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1",
    "-DSQLITE_LIKE_DOESNT_MATCH_BLOBS",
    "-DSQLITE_OMIT_DEPRECATED",
    "-DSQLITE_OMIT_LOAD_EXTENSION",
    "-DSQLITE_DQS=0",
    "-DSQLITE_USE_ALLOCA",
};

/// FreeType's module-level unity sources. This is the standard minimal set:
/// the base API plus the font formats and rasterizers an editor needs.
const freetype_sources = [_][]const u8{
    "src/base/ftinit.c",   "src/base/ftsystem.c", "src/base/ftdebug.c",
    "src/base/ftbase.c",   "src/base/ftbbox.c",   "src/base/ftbitmap.c",
    "src/base/ftglyph.c",  "src/base/ftstroke.c", "src/base/ftsynth.c",
    "src/base/fttype1.c",  "src/base/ftmm.c",     "src/base/ftfstype.c",
    "src/base/ftgasp.c",   "src/base/ftpatent.c",
    "src/autofit/autofit.c",
    "src/cff/cff.c",
    "src/psaux/psaux.c",
    "src/pshinter/pshinter.c",
    "src/psnames/psnames.c",
    "src/raster/raster.c",
    "src/sfnt/sfnt.c",
    "src/smooth/smooth.c",
    "src/truetype/truetype.c",
    "src/type1/type1.c",
    "src/cid/type1cid.c",
    // WOFF support in `sfnt` calls into this; it carries its own zlib copy.
    "src/gzip/ftgzip.c",
};

const freetype_flags = [_][]const u8{
    "-DFT2_BUILD_LIBRARY",
    // These are `#ifdef` switches, so they must be *undefined* rather than
    // defined to 0 -- defining them at all pulls in libpng, system zlib and
    // brotli, none of which are vendored here.
    "-UFT_CONFIG_OPTION_SYSTEM_ZLIB",
    "-UFT_CONFIG_OPTION_USE_PNG",
    "-UFT_CONFIG_OPTION_USE_HARFBUZZ",
    "-UFT_CONFIG_OPTION_USE_BROTLI",
    // A trimmed module list; see vendor/freetype-config/novaftmodule.h.
    "-DFT_CONFIG_MODULES_H=<novaftmodule.h>",
    "-fno-sanitize=undefined",
};

/// HarfBuzz ships a unity translation unit that includes every other source.
const harfbuzz_flags = [_][]const u8{
    "-std=c++11",
    "-fno-exceptions",
    "-fno-rtti",
    "-fno-threadsafe-statics",
    "-DHAVE_FREETYPE=1",
    "-DHB_NO_MMAP=1",
    "-fno-sanitize=undefined",
};

/// Compile FreeType and HarfBuzz into `mod`.
///
/// Both are vendored and built from source rather than pulled in as packages:
/// it keeps the build hermetic and cross-compilable, and it is the same
/// approach already used for SQLite.
fn linkTextStack(b: *std.Build, mod: *std.Build.Module) void {
    mod.addIncludePath(b.path("vendor/freetype/include"));
    mod.addIncludePath(b.path("vendor/freetype-config"));
    for (freetype_sources) |src| {
        mod.addCSourceFile(.{
            .file = b.path(b.fmt("vendor/freetype/{s}", .{src})),
            .flags = &freetype_flags,
        });
    }

    mod.addIncludePath(b.path("vendor/harfbuzz/src"));
    mod.addCSourceFile(.{
        .file = b.path("vendor/harfbuzz/src/harfbuzz.cc"),
        .flags = &harfbuzz_flags,
    });
    mod.link_libcpp = true;
}

/// Turn off mingw's fortified string wrappers.
///
/// `_mingw.h` only defines them when the compiler reports optimization, so they
/// appear in release builds and not in debug ones. Translating them trips a
/// bug in translate-c: the generated wrapper declares a local `extern` struct
/// for the checked function and never references it, which Zig rejects as an
/// unused local constant. Nothing here calls `wcscat`/`strcpy` and friends
/// through the C headers, so the fortified variants are pure loss.
fn disableMingwFortify(mod: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    if (target.result.os.tag != .windows) return;
    mod.addCMacro("_FORTIFY_SOURCE", "0");
}

/// The macOS menu bar talks to AppKit through the Objective-C runtime, so both
/// have to be linked. SDL happens to pull them in for its own Cocoa backend,
/// but depending on that would leave the menu silently broken the day SDL's
/// backend changes.
fn linkMacosMenu(mod: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    if (!target.result.os.tag.isDarwin()) return;
    mod.linkSystemLibrary("objc", .{});
    mod.linkFramework("AppKit", .{});
}

/// Assemble `Nova.app`.
///
/// The bundle is pure file layout -- a binary, a plist and an icon in the right
/// places -- so it is built by the Zig build system rather than a shell script,
/// and can be assembled (and checked) on any host. Only the `.dmg` around it
/// needs macOS, because `hdiutil` does; see tools/package-macos.sh.
fn addMacosBundle(b: *std.Build, exe: *std.Build.Step.Compile, target: std.Build.ResolvedTarget) void {
    const app = "Nova.app";

    const plist = b.fmt(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>CFBundleDevelopmentRegion</key>
        \\    <string>en</string>
        \\    <key>CFBundleDisplayName</key>
        \\    <string>Nova</string>
        \\    <key>CFBundleExecutable</key>
        \\    <string>Nova</string>
        \\    <key>CFBundleIconFile</key>
        \\    <string>nova.icns</string>
        \\    <key>CFBundleIdentifier</key>
        \\    <string>com.oein.nova</string>
        \\    <key>CFBundleInfoDictionaryVersion</key>
        \\    <string>6.0</string>
        \\    <key>CFBundleName</key>
        \\    <string>Nova</string>
        \\    <key>CFBundlePackageType</key>
        \\    <string>APPL</string>
        \\    <key>CFBundleShortVersionString</key>
        \\    <string>{s}</string>
        \\    <key>CFBundleVersion</key>
        \\    <string>{s}</string>
        \\    <key>LSApplicationCategoryType</key>
        \\    <string>public.app-category.productivity</string>
        \\    <key>LSMinimumSystemVersion</key>
        \\    <string>11.0</string>
        \\    <key>NSHighResolutionCapable</key>
        \\    <true/>
        \\    <key>NSSupportsAutomaticGraphicsSwitching</key>
        \\    <true/>
        \\</dict>
        \\</plist>
        \\
    , .{ version, version });

    const write = b.addWriteFiles();
    const plist_file = write.add("Info.plist", plist);
    // `APPL????` is the classic package-type marker; Finder still reads it.
    const pkg_info = write.add("PkgInfo", "APPL????");

    const step = b.step("bundle", "Assemble Nova.app (macOS)");
    step.dependOn(&b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = app ++ "/Contents/MacOS" } },
    }).step);
    step.dependOn(&b.addInstallFile(plist_file, app ++ "/Contents/Info.plist").step);
    step.dependOn(&b.addInstallFile(pkg_info, app ++ "/Contents/PkgInfo").step);
    step.dependOn(&b.addInstallFile(
        b.path("assets/icons/nova.icns"),
        app ++ "/Contents/Resources/nova.icns",
    ).step);

    if (!target.result.os.tag.isDarwin()) {
        // Assembling the layout off macOS is useful for checking it; running the
        // result is not, so say so once rather than shipping a broken bundle.
        step.dependOn(&b.addSystemCommand(&.{
            "echo",
            "note: bundle assembled for a non-macOS target -- layout only, it will not run",
        }).step);
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Stage 1: pure editor and search logic. No platform, no rendering, no I/O.
    const core = b.addModule("core", .{
        .root_source_file = b.path("src/core/core.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Stage 2: workspace storage. SQLite plus the note/session/search layer.
    const db = b.addModule("db", .{
        .root_source_file = b.path("src/db/db.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    db.addIncludePath(b.path("vendor/sqlite"));
    db.addCSourceFile(.{
        .file = b.path("vendor/sqlite/sqlite3.c"),
        .flags = &sqlite_flags,
    });
    db.addImport("core", core);
    disableMingwFortify(db, target);

    // Per-OS glue: local time, opening URLs, revealing files.
    const platform = b.addModule("platform", .{
        .root_source_file = b.path("src/platform/platform.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    linkMacosMenu(platform, target);
    disableMingwFortify(platform, target);

    // Stage 4: networking -- the update check and Notion sync.
    const net = b.addModule("net", .{
        .root_source_file = b.path("src/net/net.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    net.addImport("core", core);
    net.addImport("db", db);

    // Stage 2: application state -- tabs, session, auto-save, note list.
    const app = b.addModule("app", .{
        .root_source_file = b.path("src/app/app.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    app.addImport("core", core);
    app.addImport("db", db);
    app.addImport("platform", platform);
    app.addImport("net", net);

    // Stage 3: rendering. Glyph rasterization, shaping, and the painter.
    const gfx = b.addModule("gfx", .{
        .root_source_file = b.path("src/gfx/gfx.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    gfx.addImport("core", core);
    linkTextStack(b, gfx);
    disableMingwFortify(gfx, target);
    // Fonts are compiled into the binary. See assets/fonts/README.md for why
    // Nova ships its own rather than asking the OS.
    gfx.addAnonymousImport("font_default", .{
        .root_source_file = b.path("assets/fonts/D2Coding-Regular.ttf"),
    });

    // The UI: widgets and screens. Draws through `gfx` and consumes abstract
    // input events, so every screen can be rendered and driven headlessly.
    const ui = b.addModule("ui", .{
        .root_source_file = b.path("src/ui/ui.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    ui.addImport("core", core);
    ui.addImport("db", db);
    ui.addImport("app", app);
    ui.addImport("gfx", gfx);
    ui.addImport("platform", platform);
    ui.addImport("net", net);

    // The shell: SDL window, event loop, IME, clipboard. The only part of the
    // program that knows a window exists.
    // Cross-compiling SDL to macOS needs a real macOS SDK: Zig bundles the
    // libSystem stub but no frameworks, and SDL's Cocoa/Metal backends need
    // them. These options forward the SDK paths through to SDL so a machine
    // that *has* an SDK can cross-build; without them, macOS is built natively
    // (which is what CI does).
    const sdk_include = b.option([]const u8, "macos-sdk-include", "macOS SDK usr/include path");
    const sdk_frameworks = b.option([]const u8, "macos-sdk-frameworks", "macOS SDK System/Library/Frameworks path");
    const sdk_libs = b.option([]const u8, "macos-sdk-libs", "macOS SDK usr/lib path");

    const sdl_dep = if (sdk_include != null and sdk_frameworks != null and sdk_libs != null)
        b.dependency("sdl", .{
            .target = target,
            .optimize = optimize,
            .system_include_path = sdk_include.?,
            .system_framework_path = sdk_frameworks.?,
            .library_path = sdk_libs.?,
        })
    else
        b.dependency("sdl", .{ .target = target, .optimize = optimize });
    const exe = b.addExecutable(.{
        .name = "Nova",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    disableMingwFortify(exe.root_module, target);
    exe.root_module.addImport("core", core);
    exe.root_module.addImport("db", db);
    exe.root_module.addImport("app", app);
    exe.root_module.addImport("gfx", gfx);
    exe.root_module.addImport("ui", ui);
    exe.root_module.addImport("platform", platform);
    exe.root_module.addImport("net", net);
    exe.root_module.linkLibrary(sdl_dep.artifact("SDL3"));
    linkMacosMenu(exe.root_module, target);
    b.installArtifact(exe);

    addMacosBundle(b, exe, target);

    const run_step = b.step("run", "Run Nova");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run tests");
    for ([_]*std.Build.Module{ core, db, platform, app, gfx, ui, net }) |mod| {
        const t = b.addTest(.{ .root_module = mod });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
    // The shell is tested through the executable's module, since it links SDL.
    const shell_tests = b.addTest(.{ .root_module = exe.root_module });
    test_step.dependOn(&b.addRunArtifact(shell_tests).step);
}
