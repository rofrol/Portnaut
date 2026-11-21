import Foundation

/// A file an engine profile is built from, pinned by its SHA-256.
public struct ProfileDownload: Sendable, Equatable {
    public var url: URL
    public var fileName: String
    public var sha256: String
    public var size: Int64?
}

/// A whole Wine engine for one game family, used by a bottle in place of Portnaut's runtime and
/// renderer. Portnaut's Highball Wine lacks what some games need from Wine itself; a profile pins
/// a third-party engine that has it. Nothing of the profile ships with Portnaut: its parts are
/// downloaded from their publishers and checked against the hashes below.
///
/// gta5Enhanced is the GTA V Enhanced environment of MacGames 0.1.6 (https://github.com/tarikbc/macgames):
/// its Wine 11.13 engine with the gta5 overlay (Rockstar Games Launcher feature-level and GTA D3D12Core
/// patches), Apple's D3DMetal 4.0b2 for the game, and WineD3D builds of d3d11, dxgi and d3d10core for the
/// Rockstar Games Launcher and Social Club, which do not start on D3DMetal. The layout mirrors MacGames'
/// GameEnvironment.gta5, PrefixSetup.graphicsCopies and GameRecipes.registry("gta5-enhanced").
public enum EngineProfile: String, Codable, CaseIterable, Sendable, Identifiable {
    case gta5Enhanced = "gta5-enhanced"
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .gta5Enhanced: "GTA V Enhanced (MacGames engine)"
        }
    }

    public var detail: String {
        switch self {
        case .gta5Enhanced: "MacGames’ Wine 11.13 with its GTA V patches and Apple’s D3DMetal 4.0b2 for the game; the Rockstar Games Launcher draws with Wine’s own Direct3D. Replaces the bottle’s renderer."
        }
    }

    /// Shown wherever the profile can be chosen: the parts' own licences apply.
    public var licenseNote: String {
        switch self {
        case .gta5Enhanced: "Downloaded from MacGames’ releases (engine and packs) and Sikarugir’s template. D3DMetal is Apple’s, from the Game Porting Toolkit; its licence covers non-commercial use for developing, testing and evaluating games on Apple hardware."
        }
    }

    static let macGamesApp = "MacGames.app/Contents/Resources/Runtime"
    static let templateApp = "Template-1.0.15.app/Contents/Frameworks"
    static let d3dmetalPack = "apple-d3dmetal-4.0b2"

    /// MacGames 0.1.6's app (only its Runtime/Engine and dependency links are used), Sikarugir's template
    /// 1.0.15 (the engine's libraries) and MacGames' packs-1 release, with the hashes MacGames pins
    /// (Packs.swift, Downloader.swift) and the app's from its release.
    public var downloads: [ProfileDownload] {
        switch self {
        case .gta5Enhanced:
            let packs = "https://github.com/tarikbc/macgames/releases/download/packs-1/"
            return [
                ProfileDownload(url: URL(string: "https://github.com/tarikbc/macgames/releases/download/v0.1.6/MacGames-0.1.6.zip")!, fileName: "MacGames-0.1.6.zip",
                                sha256: "c236645a868ef708df43705cdce521c951b710166da0fb2d9186bc6da82c5f94", size: 154_946_645),
                ProfileDownload(url: URL(string: "https://github.com/Sikarugir-App/Wrapper/releases/download/v1.0/Template-1.0.15.tar.xz")!, fileName: "Template-1.0.15.tar.xz",
                                sha256: "34273bcce885ce5a7fd6937af9ea344bb9961de7d55d6193f7413142e835c8c3"),
                ProfileDownload(url: URL(string: packs + "macgames-pack-gta5.tar.xz")!, fileName: "macgames-pack-gta5.tar.xz",
                                sha256: "bc8d15d5ad6713e6a192de6d78e0534a2925db886d7a9225efdf52c25fcc7499", size: 134_419_392),
                ProfileDownload(url: URL(string: packs + "macgames-pack-rockstar.tar.xz")!, fileName: "macgames-pack-rockstar.tar.xz",
                                sha256: "6757715792fe378758ef880ee9a433882ab6083044928ba1befbdda6f8598639", size: 728_072),
                ProfileDownload(url: URL(string: packs + "macgames-pack-\(Self.d3dmetalPack).tar.xz")!, fileName: "macgames-pack-\(Self.d3dmetalPack).tar.xz",
                                sha256: "209a9203864a0618d686096162f75ce506838fcfe3a715b997f87759dbbee02e", size: 15_870_444),
            ]
        }
    }

    var engineArchive: String { downloads[0].fileName }
    var templateArchive: String { downloads[1].fileName }
    /// MacGames packs unpacked under packs/, and the overlays from them copied over the engine.
    var packs: [String] { ["gta5", "rockstar", Self.d3dmetalPack] }
    var overlays: [String] { ["gta5"] }

    /// Written into the built profile; a different value rebuilds it.
    var marker: String { "\(rawValue)-v1:" + downloads.map(\.sha256).joined(separator: "+") }

    // MARK: - Layout

    /// The engine's libraries load from @loader_path/../../deps/Frameworks, so engine/ and deps/ are siblings.
    public struct Layout: Sendable {
        public let root: URL
        public var engine: URL { root.appendingPathComponent("engine") }
        public var frameworks: URL { root.appendingPathComponent("deps/Frameworks") }
        public func pack(_ name: String) -> URL { root.appendingPathComponent("packs/\(name)") }
        public var d3dmetal: URL { pack(EngineProfile.d3dmetalPack) }
        public var markerFile: URL { root.appendingPathComponent(".portnaut-engine-profile") }
    }

    /// Where a dependency link of MacGames' engine points, relative to the profile's root: a D3DMetal file
    /// from the pinned D3DMetal pack when the pack has it (its DLLs and libd3dshared must come from one
    /// D3DMetal), otherwise the template's file. Mirrors MacGames' EngineInstaller.ownD3DMetal.
    static func linkTarget(_ target: String, d3dmetalHas: (String) -> Bool) -> String {
        let prefix = "renderer/d3dmetal/"
        if target.hasPrefix(prefix) {
            let rest = String(target.dropFirst(prefix.count))
            if d3dmetalHas(rest) { return "packs/\(d3dmetalPack)/\(rest)" }
        }
        return "deps/Frameworks/\(target)"
    }

    /// A symbolic link at `link` (relative to the profile's root) to `target` (also relative to it),
    /// written relative so the profile can be built in a staging folder and moved into place.
    static func relativeLink(from link: String, to target: String) -> String {
        let depth = link.split(separator: "/").count - 1
        return String(repeating: "../", count: depth) + target
    }

    // MARK: - Bottle

    /// The bottle's environment under this profile, built on `base` (the Mac's environment with Wine's and
    /// the renderers' variables removed). Mirrors MacGames' WineEnvironment.make() with the gta5-enhanced
    /// recipe's edits; WINEDLLOVERRIDES carries no graphics overrides, so per-program registry overrides decide.
    func environment(base: [String: String], layout: Layout, prefix: URL, bottle: Bottle, cache: URL) -> [String: String] {
        // MacGames also strips these inherited keys before building its environment.
        var env = base.filter { key, _ in !key.hasPrefix("GST_") && !key.hasPrefix("ROSETTA_") && !key.hasPrefix("MTL_") && !key.hasPrefix("SDL_") }
        let gst = layout.frameworks.appendingPathComponent("GStreamer.framework/Versions/1.0/lib")
        env["PATH"] = layout.engine.appendingPathComponent("bin").path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        env["WINEPREFIX"] = prefix.path
        env["WINEARCH"] = "win64"
        // MacGames' GTA V environment turns msync off; the game was tested that way.
        env["WINEMSYNC"] = "0"
        env["WINEESYNC"] = "0"
        env["WINEDLLOVERRIDES"] = "winemenubuilder.exe=;mscoree,mshtml=;gameoverlayrenderer,gameoverlayrenderer64=;nvapi64,nvngx="
        // D3DMetal's builtins first, for the game; the launcher takes WineD3D from system32 (native,builtin).
        env["WINEDLLPATH"] = layout.d3dmetal.appendingPathComponent("wine").path + ":" + layout.engine.appendingPathComponent("lib/wine").path
        env["WINEDEBUG"] = ProcessInfo.processInfo.environment["PORTNAUT_WINEDEBUG"] ?? "-all,err+all"
        env["DYLD_FALLBACK_LIBRARY_PATH"] = [layout.frameworks.path, gst.path, "/usr/lib"].joined(separator: ":")
        env["GST_PLUGIN_PATH"] = gst.appendingPathComponent("gstreamer-1.0").path
        env["GST_REGISTRY"] = cache.appendingPathComponent("gstreamer-registry-\(rawValue).bin").path
        env["CX_APPLEGPTK_LIBD3DSHARED_PATH"] = layout.d3dmetal.appendingPathComponent("external/libd3dshared.dylib").path
        env["ROSETTA_ADVERTISE_AVX"] = "1"
        env["MTL_HUD_ENABLED"] = bottle.options.performanceHUD ? "1" : "0"
        env["D3DM_ENABLE_METALFX"] = "0"
        // Read by the gta5 overlay's patches: Social Club's browser draws on the CPU.
        env["GTM_ROCKSTAR_SWIFTSHADER"] = "1"
        // The Windows user MacGames' engine expects; the launcher signs in as it.
        env["USER"] = "crossover"
        env["LOGNAME"] = "crossover"
        return env
    }

    /// Registry values written after the bottle's own, so the profile's per-program overrides win over a
    /// game's: the game on D3DMetal's builtins, the launcher and Social Club on WineD3D from system32
    /// without Direct3D 12. Portnaut's own Social Club switches are removed; this engine draws it itself.
    var registry: String {
        switch self {
        case .gta5Enhanced:
            let key = "HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\"
            var lines: [String] = []
            lines += ["[\(key)GTA5_Enhanced.exe\\DllOverrides]"] + ["dxgi", "d3d11", "d3d10core", "d3d12", "atidxx64"].map { "\"\($0)\"=\"builtin\"" } + [""]
            for program in ["Launcher.exe", "LauncherPatcher.exe", "SocialClubHelper.exe"] {
                lines += ["[\(key)\(program)\\DllOverrides]"] + ["dxgi", "d3d11", "d3d10core"].map { "\"\($0)\"=\"native,builtin\"" } + ["\"d3d12\"=\"\""]
                if program == "SocialClubHelper.exe" { lines.append("\"vulkan-1\"=\"native\"") }
                lines.append("")
            }
            lines += ["[\(key)SocialClubHelper.exe]", "\"CommandLineAppend\"=-", ""]
            // Keeps the cursor from flickering in fullscreen (Wine captures the display instead of covering it).
            lines += ["[HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver]", "\"CaptureDisplaysForFullscreen\"=\"y\"", ""]
            return lines.joined(separator: "\n") + "\n"
        }
    }

    /// Removes every value `registry` writes, imported before the bottle's own profile when the bottle
    /// leaves this engine, so the values a game or launcher of the bottle sets come back after it.
    var cleanupRegistry: String {
        registry.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard line.hasPrefix("\""), let end = line.dropFirst().firstIndex(of: "\"") else { return String(line) }
            return String(line[...end]) + "=-"
        }.joined(separator: "\n")
    }

    /// The names systemCopies writes into system32, each once.
    func systemNames(layout: Layout) -> [String] {
        var seen = Set<String>()
        return systemCopies(layout: layout).map(\.name).filter { seen.insert($0).inserted }
    }

    /// Files copied into the prefix's system32, later ones replacing earlier ones: D3DMetal's dxgi, d3d11
    /// and d3d12 and the template's atidxx64, then the rockstar pack's WineD3D d3d11, dxgi and d3d10core.
    func systemCopies(layout: Layout) -> [(from: URL, name: String)] {
        let d3dmetal = layout.d3dmetal.appendingPathComponent("wine/x86_64-windows")
        let template = layout.frameworks.appendingPathComponent("renderer/d3dmetal/wine/x86_64-windows")
        let wined3d = layout.pack("rockstar").appendingPathComponent("RockstarRenderer")
        return ["dxgi", "d3d11", "d3d12"].map { (d3dmetal.appendingPathComponent("\($0).dll"), "\($0).dll") }
            + [(template.appendingPathComponent("atidxx64.dll"), "atidxx64.dll")]
            + ["d3d11", "dxgi", "d3d10core"].map { (wined3d.appendingPathComponent("\($0).dll"), "\($0).dll") }
    }

    /// The game's arguments live in commandline.txt: the launcher starts GTA5_Enhanced.exe with
    /// @commandline.txt. Without -disableSpatialAudioClient voices and most effects are silent under
    /// Wine; -nobattleye skips BattlEye, which is for GTA Online only (tested).
    static let gameFolder = "Program Files/Rockstar Games/Grand Theft Auto V Enhanced"
    static let gameArguments = ["-disableSpatialAudioClient", "-nobattleye"]

    /// The commandline.txt contents with the required arguments added to the user's, each once.
    static func commandLine(merging existing: String?) -> String {
        var lines = (existing ?? "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let present = Set(lines.flatMap { $0.split(separator: " ").map { $0.lowercased() } })
        lines += gameArguments.filter { !present.contains($0.lowercased()) }
        return lines.joined(separator: "\n") + "\n"
    }
}
