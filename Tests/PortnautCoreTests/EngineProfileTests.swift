import Foundation
import Testing
@testable import PortnautCore

@Suite
struct EngineProfileTests {
    func gtaBottle() -> Bottle {
        var bottle = Bottle(id: "gta", name: "GTA V", launcher: .rockstar, renderer: .d3dmetal)
        bottle.engineProfile = .gta5Enhanced
        return bottle
    }

    @Test func libraryWithoutProfileStillLoads() throws {
        let json = #"{"id":"b","name":"B","renderer":"dxmt"}"#
        let bottle = try JSONDecoder().decode(Bottle.self, from: Data(json.utf8))
        #expect(bottle.engineProfile == nil)
        let saved = try JSONDecoder().decode(Bottle.self, from: JSONEncoder().encode(gtaBottle()))
        #expect(saved.engineProfile == .gta5Enhanced)
    }

    @Test func profileBottleRunsOnTheProfileEngine() {
        let paths = PortnautPaths(root: URL(fileURLWithPath: "/tmp/portnaut-root"))
        let engine = paths.profile(.gta5Enhanced).engine
        #expect(paths.wine(for: gtaBottle()) == engine.appendingPathComponent("bin/wine"))
        #expect(paths.wineserver(for: gtaBottle()) == engine.appendingPathComponent("bin/wineserver"))
        let plain = Bottle(id: "p", name: "P", renderer: .dxmt)
        #expect(paths.wine(for: plain) == paths.wine(for: Renderer.dxmt))
    }

    /// No graphics override in the environment: the per-program registry decides between D3DMetal and WineD3D.
    @Test func environmentLeavesGraphicsToThePrograms() {
        let service = WineService(paths: PortnautPaths(root: URL(fileURLWithPath: "/tmp/portnaut-root")), metalShim: URL(fileURLWithPath: "/tmp/shim.dylib"))
        var bottle = gtaBottle()
        bottle.environment = ["WINEDLLOVERRIDES": "d3d12=n", "MY_FLAG": "1"]
        let env = service.environment(for: bottle)
        let overrides = env["WINEDLLOVERRIDES"] ?? ""
        for dll in ["dxgi", "d3d11", "d3d12", "d3d10core"] { #expect(!overrides.contains(dll)) }
        #expect(overrides.contains("nvapi64,nvngx="))
        #expect(env["DYLD_INSERT_LIBRARIES"] == nil)
        #expect(env["WINEDLLPATH"]?.hasPrefix(service.paths.profile(.gta5Enhanced).d3dmetal.appendingPathComponent("wine").path + ":") == true)
        #expect(env["WINEMSYNC"] == "0")
        #expect(env["USER"] == "crossover")
        #expect(env["MY_FLAG"] == "1")
        #expect(env["PATH"]?.hasPrefix(service.paths.profile(.gta5Enhanced).engine.path) == true)
    }

    /// Portnaut's renderer options do not reach the profile's engine.
    @Test func rendererOptionsDoNotLeakIntoTheProfile() {
        let service = WineService(paths: PortnautPaths(root: URL(fileURLWithPath: "/tmp/portnaut-root")), metalShim: nil)
        var bottle = gtaBottle()
        bottle.renderer = .dxmt
        bottle.msync = true
        bottle.options.metalFXUpscaling = true
        bottle.options.dlss = true
        #expect(!bottle.metalFXActive && !bottle.dlssActive && bottle.retinaMode)
        let env = service.environment(for: bottle)
        #expect(env["WINEMSYNC"] == "0")
        #expect(env["D3DM_ENABLE_METALFX"] == "0")
        #expect(!env.keys.contains { $0.hasPrefix("DXMT_") })
        #expect(env["DYLD_FALLBACK_LIBRARY_PATH"]?.contains("/Libraries") == false)
        #expect(env["GTM_ROCKSTAR_SWIFTSHADER"] == "1")
    }

    /// Portnaut's Social Club switches are written first and removed by the profile, whatever the launcher.
    @Test func socialClubSwitchesAreRemoved() {
        for launcher in [Launcher.rockstar, .steam] {
            var bottle = gtaBottle()
            bottle.launcher = launcher
            let registry = WineService.profile(for: bottle)
            let added = registry.range(of: "\"CommandLineAppend\"=\"")
            let removed = registry.range(of: "\"CommandLineAppend\"=-")
            #expect(removed != nil)
            if let added, launcher == .rockstar { #expect(added.lowerBound < removed!.lowerBound) }
        }
    }

    @Test func gameArgumentsAreWrittenOnceTheGameIsInstalled() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("portnaut-profile-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = WineService(paths: PortnautPaths(root: root), metalShim: nil)
        let bottlePaths = service.paths.bottle(gtaBottle())
        try FileManager.default.createDirectory(at: bottlePaths.drive, withIntermediateDirectories: true)
        try service.writeGameArguments(to: bottlePaths)
        let folder = bottlePaths.drive.appendingPathComponent(EngineProfile.gameFolder)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("commandline.txt")
        try Data("-windowed\n".utf8).write(to: file)
        try service.writeGameArguments(to: bottlePaths)
        #expect(try String(contentsOf: file, encoding: .utf8) == "-windowed\n-disableSpatialAudioClient\n-nobattleye\n")
        let utf16 = "-windowed".data(using: .utf16)!
        try utf16.write(to: file)
        try service.writeGameArguments(to: bottlePaths)
        #expect(try Data(contentsOf: file) == utf16)
    }

    /// The profile's per-program overrides come after a game's own, so they win.
    @Test func profileRegistryComesLast() {
        var bottle = gtaBottle()
        var game = Game(id: "gta5", name: "GTA V Enhanced", executable: EngineProfile.gameFolder + "/GTA5_Enhanced.exe")
        game.dllOverrides = ["dxgi": .native]
        bottle.games = [game]
        let registry = WineService.profile(for: bottle)
        let key = "[HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\GTA5_Enhanced.exe\\DllOverrides]"
        let gameKey = registry.range(of: key)
        let profileKey = registry.range(of: key, options: .backwards)
        #expect(gameKey != nil && profileKey != nil && gameKey!.lowerBound < profileKey!.lowerBound)
        #expect(registry.hasSuffix(EngineProfile.gta5Enhanced.registry))
        #expect(registry.contains("\"CaptureDisplaysForFullscreen\"=\"y\""))
        #expect(!WineService.profile(for: Bottle(id: "p", name: "P", renderer: .dxmt)).contains("CaptureDisplaysForFullscreen"))
    }

    @Test func launcherGetsWineD3DAndGameGetsD3DMetal() {
        let copies = EngineProfile.gta5Enhanced.systemCopies(layout: EngineProfile.Layout(root: URL(fileURLWithPath: "/p")))
        var final: [String: String] = [:]
        for copy in copies { final[copy.name] = copy.from.path }
        #expect(final["dxgi.dll"] == "/p/packs/rockstar/RockstarRenderer/dxgi.dll")
        #expect(final["d3d11.dll"] == "/p/packs/rockstar/RockstarRenderer/d3d11.dll")
        #expect(final["d3d10core.dll"] == "/p/packs/rockstar/RockstarRenderer/d3d10core.dll")
        #expect(final["d3d12.dll"] == "/p/packs/apple-d3dmetal-4.0b2/wine/x86_64-windows/d3d12.dll")
        #expect(final["atidxx64.dll"] == "/p/deps/Frameworks/renderer/d3dmetal/wine/x86_64-windows/atidxx64.dll")
    }

    @Test func linksResolveInsideTheProfile() {
        #expect(EngineProfile.linkTarget("renderer/d3dmetal/wine/x86_64-windows/dxgi.dll") { _ in true }
                == "packs/apple-d3dmetal-4.0b2/wine/x86_64-windows/dxgi.dll")
        #expect(EngineProfile.linkTarget("renderer/d3dmetal/wine/x86_64-windows/atidxx64.dll") { _ in false }
                == "deps/Frameworks/renderer/d3dmetal/wine/x86_64-windows/atidxx64.dll")
        #expect(EngineProfile.linkTarget("libfreetype.6.dylib") { _ in true } == "deps/Frameworks/libfreetype.6.dylib")
        #expect(EngineProfile.relativeLink(from: "engine/lib/wine/x86_64-windows/dxgi.dll", to: "packs/x/dxgi.dll") == "../../../../packs/x/dxgi.dll")
        let base = URL(fileURLWithPath: "/root/engine/lib/wine/x86_64-windows/")
        #expect(URL(fileURLWithPath: "../../../../packs/x/dxgi.dll", relativeTo: base).standardizedFileURL.path == "/root/packs/x/dxgi.dll")
    }

    @Test func commandLineKeepsTheUsersArgumentsAndAddsEachRequiredOnce() {
        #expect(EngineProfile.commandLine(merging: nil) == "-disableSpatialAudioClient\n-nobattleye\n")
        #expect(EngineProfile.commandLine(merging: "-windowed\n-nobattleye\n") == "-windowed\n-nobattleye\n-disableSpatialAudioClient\n")
        let once = EngineProfile.commandLine(merging: "-fullscreen")
        #expect(EngineProfile.commandLine(merging: once) == once)
    }
}
