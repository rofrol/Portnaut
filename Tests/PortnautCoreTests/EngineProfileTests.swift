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
        // With a byte-order mark, and without one in either byte order (ASCII only, so also valid UTF-8).
        for encoding in [String.Encoding.utf16, .utf16LittleEndian, .utf16BigEndian] {
            let utf16 = "-windowed".data(using: encoding)!
            try utf16.write(to: file)
            try service.writeGameArguments(to: bottlePaths)
            #expect(try Data(contentsOf: file) == utf16)
        }
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
        #expect(final["dxgi.dll"] == "/p/launcher-wined3d/dxgi.dll")
        #expect(final["d3d11.dll"] == "/p/launcher-wined3d/d3d11.dll")
        #expect(final["d3d10core.dll"] == "/p/launcher-wined3d/d3d10core.dll")
        #expect(final["d3d12.dll"] == "/p/packs/sikarugir-d3dmetal-4.0b3/wine/x86_64-windows/d3d12.dll")
        #expect(final["atidxx64.dll"] == "/p/deps/Frameworks/renderer/d3dmetal/wine/x86_64-windows/atidxx64.dll")
    }

    /// An installed Portnaut downloads nothing from MacGames to play GTA V (the user, 2026-11-21).
    @Test func profileDownloadsNothingFromMacGames() {
        for profile in EngineProfile.allCases {
            for download in profile.downloads { #expect(!download.url.path.lowercased().hasPrefix("/tarikbc/"), "\(download.url)") }
        }
    }

    @Test func linksResolveInsideTheProfile() {
        #expect(EngineProfile.linkTarget("renderer/d3dmetal/wine/x86_64-windows/dxgi.dll") { _ in true }
                == "packs/sikarugir-d3dmetal-4.0b3/wine/x86_64-windows/dxgi.dll")
        #expect(EngineProfile.linkTarget("renderer/d3dmetal/wine/x86_64-windows/atidxx64.dll") { _ in false }
                == "deps/Frameworks/renderer/d3dmetal/wine/x86_64-windows/atidxx64.dll")
        #expect(EngineProfile.linkTarget("libfreetype.6.dylib") { _ in true } == "deps/Frameworks/libfreetype.6.dylib")
        // D3DMetal 4.0b3's folder has the Unix side but no atidxx64.dll; that one comes from the template.
        let pack: Set = ["external/libd3dshared.dylib", "wine/x86_64-windows/d3d11.dll"]
        let targets = Dictionary(uniqueKeysWithValues: EngineProfile.engineLinks.map { ($0.link, EngineProfile.linkTarget($0.target) { pack.contains($0) }) })
        #expect(targets["lib/wine/x86_64-unix/d3d12.so"] == "packs/sikarugir-d3dmetal-4.0b3/external/libd3dshared.dylib")
        #expect(targets["lib/wine/x86_64-windows/atidxx64.dll"] == "deps/Frameworks/renderer/d3dmetal/wine/x86_64-windows/atidxx64.dll")
        // The game gets D3DMetal's dxgi from the engine's own folder, which Wine searches before WINEDLLPATH.
        let pack2: Set = ["external/libd3dshared.dylib", "wine/x86_64-windows/dxgi.dll"]
        #expect(EngineProfile.engineLinks.first { $0.link == "lib/wine/x86_64-windows/dxgi.dll" }
                    .map { EngineProfile.linkTarget($0.target) { pack2.contains($0) } } == "packs/sikarugir-d3dmetal-4.0b3/wine/x86_64-windows/dxgi.dll")
        #expect(EngineProfile.relativeLink(from: "engine/lib/wine/x86_64-windows/dxgi.dll", to: "packs/x/dxgi.dll") == "../../../../packs/x/dxgi.dll")
        let base = URL(fileURLWithPath: "/root/engine/lib/wine/x86_64-windows/")
        #expect(URL(fileURLWithPath: "../../../../packs/x/dxgi.dll", relativeTo: base).standardizedFileURL.path == "/root/packs/x/dxgi.dll")
    }

    /// Rockstar bottles are pointed at the engine profile; no other launcher has one.
    @Test func onlyRockstarBottlesRecommendTheEngineProfile() {
        #expect(Launcher.rockstar.engineProfile == .gta5Enhanced)
        #expect(Launcher.allCases.filter { $0.engineProfile != nil } == [.rockstar])
    }

    @Test func commandLineKeepsTheUsersArgumentsAndAddsEachRequiredOnce() {
        #expect(EngineProfile.commandLine(merging: nil) == "-disableSpatialAudioClient\n-nobattleye\n")
        #expect(EngineProfile.commandLine(merging: "-windowed\n-nobattleye\n") == "-windowed\n-nobattleye\n-disableSpatialAudioClient\n")
        let once = EngineProfile.commandLine(merging: "-fullscreen")
        #expect(EngineProfile.commandLine(merging: once) == once)
    }

    // MARK: - Switching engines

    /// A scratch Portnaut root whose engine profile is built: a marker, a Wine that only exits, and
    /// sentinel files for every system32 copy. Portnaut's own renderers have no Wine until fakeRuntime.
    func scratchRoot() throws -> (URL, WineService) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("portnaut-engine-" + UUID().uuidString)
        let service = WineService(paths: PortnautPaths(root: root), metalShim: nil)
        let profile = EngineProfile.gta5Enhanced
        let layout = service.paths.profile(profile)
        try fakeWine(layout.engine.appendingPathComponent("bin/wine"))
        try fakeWine(layout.engine.appendingPathComponent("bin/wineserver"))
        try Data(profile.marker.utf8).write(to: layout.markerFile)
        for copy in profile.systemCopies(layout: layout) {
            try fm.createDirectory(at: copy.from.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("profile:\(copy.from.path)".utf8).write(to: copy.from)
        }
        try service.paths.createDirectories()
        return (root, service)
    }
    /// A Wine (or wineserver) that exits with `exitCode`, or fails only the `failing` command (as `reg`). Its
    /// `reg import` counts itself in reg-calls and keeps each hive's stamp line in memory (a pending file per
    /// hive: HKEY_CURRENT_USER's for user.reg, HKEY_LOCAL_MACHINE's for system.reg); its `wineserver -w` writes
    /// them to `savedHives`, as Wine's server writes each hive on exit (none: a server killed first). `-k0`
    /// exits with `probeStatus` (0: a server runs, 1: none).
    func fakeWine(_ url: URL, exitCode: Int = 0, failing: String? = nil, savedHives: [String] = ["user.reg", "system.reg"], probeStatus: Int = 1) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // wineboot creates the folders prepareBottle's later steps use.
        let wineboot = "[ \"$1\" = wineboot ] && mkdir -p \"$WINEPREFIX/dosdevices\" \"$WINEPREFIX/drive_c/windows/system32\"\n"
        let failure = failing.map { "[ \"$1\" = \($0) ] && exit 1\n" } ?? ""
        let probe = "[ \"$1\" = -k0 ] && exit \(probeStatus)\n"
        let profile = "\"$WINEPREFIX/drive_c/Portnaut/profile.reg\""
        let keep = { (root: String, hive: String) in
            "grep -F -A1 '[\(root)\\Software\\Portnaut]' \(profile) | grep '\"EngineStamp\"' >> \"$WINEPREFIX/in-memory.\(hive)\""
        }
        let registry = "[ \"$1\" = reg ] && { echo reg >> \"$WINEPREFIX/reg-calls\"; \(keep("HKEY_CURRENT_USER", "user.reg")); \(keep("HKEY_LOCAL_MACHINE", "system.reg")); }\n"
            + "[ \"$1\" = -w ] && { for hive in \(savedHives.joined(separator: " ")); do cat \"$WINEPREFIX/in-memory.$hive\" >> \"$WINEPREFIX/$hive\" 2>/dev/null; done; rm -f \"$WINEPREFIX\"/in-memory.*; }\n"
        try Data("#!/bin/sh\n\(wineboot)\(probe)\(failure)\(registry)exit \(exitCode)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    func fakeRuntime(_ service: WineService) throws {
        for renderer in Renderer.allCases { try fakeWine(service.paths.wine(for: renderer)); try fakeWine(service.paths.wineserver(for: renderer)) }
    }

    /// A ready bottle in the library, with Portnaut's dxgi, d3d11 and d3d10core in system32 and no d3d12 or atidxx64.
    func readyBottle(_ bottle: Bottle, in service: WineService) throws -> BottlePaths {
        let fm = FileManager.default
        let bottlePaths = service.paths.bottle(bottle)
        let system32 = bottlePaths.drive.appendingPathComponent("windows/system32")
        try fm.createDirectory(at: system32, withIntermediateDirectories: true)
        try fm.createDirectory(at: bottlePaths.prefix.appendingPathComponent("dosdevices"), withIntermediateDirectories: true)
        for name in ["dxgi.dll", "d3d11.dll", "d3d10core.dll"] { try Data("original:\(name)".utf8).write(to: system32.appendingPathComponent(name)) }
        try Data().write(to: bottlePaths.prefix.appendingPathComponent("system.reg"))
        try Data("portnaut-bottle-v1\n".utf8).write(to: bottlePaths.marker)
        try service.paths.saveLibrary(Library(bottles: [bottle]))
        return bottlePaths
    }

    func contents(_ url: URL) -> String? { (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } }

    /// A bottle created with the profile is set up on it: saved with it, its system32 holding the profile's files.
    @Test func aBottleCreatedOnTheProfileStartsOnIt() async throws {
        let (root, service) = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try fakeRuntime(service)
        try Data().write(to: service.paths.runtimeMarker)
        try FileManager.default.createDirectory(at: service.paths.libraries, withIntermediateDirectories: true)
        try Data().write(to: service.paths.libraries.appendingPathComponent("libinotify.0.dylib"))
        let bottle = try await service.createBottle(name: "Rockstar Games Launcher", launcher: .rockstar, renderer: .dxmt, engineProfile: .gta5Enhanced)
        #expect(bottle.id == "rockstar-games-launcher")
        #expect(try service.bottle(bottle.id).engineProfile == .gta5Enhanced)
        let system32 = service.paths.bottle(bottle).drive.appendingPathComponent("windows/system32")
        #expect(contents(system32.appendingPathComponent("dxgi.dll"))?.contains("launcher-wined3d") == true)
        #expect(contents(system32.appendingPathComponent("d3d12.dll"))?.hasPrefix("profile:") == true)
    }

    /// A failed creation removes only the folder it reserved: a folder left by a bottle no longer in the
    /// library keeps its contents, and the new bottle takes the next free name.
    @Test func aFailedCreationLeavesAnUnlistedFolderAlone() async throws {
        let (root, service) = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try fakeRuntime(service)
        try Data().write(to: service.paths.runtimeMarker)
        try FileManager.default.createDirectory(at: service.paths.libraries, withIntermediateDirectories: true)
        try Data().write(to: service.paths.libraries.appendingPathComponent("libinotify.0.dylib"))
        #expect(service.paths.runtimeReady)
        try fakeWine(service.paths.profile(.gta5Enhanced).engine.appendingPathComponent("bin/wine"), exitCode: 1)
        try service.paths.saveLibrary(Library())
        let leftover = service.paths.bottles.appendingPathComponent("rockstar-games-launcher/drive_c/saves.dat")
        try FileManager.default.createDirectory(at: leftover.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("kept".utf8).write(to: leftover)
        await #expect(throws: (any Error).self) {
            _ = try await service.createBottle(name: "Rockstar Games Launcher", launcher: .rockstar, renderer: .dxmt, engineProfile: .gta5Enhanced)
        }
        #expect(contents(leftover) == "kept")
        #expect(!FileManager.default.fileExists(atPath: service.paths.bottles.appendingPathComponent("rockstar-games-launcher-2").path))
        #expect(try service.paths.loadLibrary().bottles.isEmpty)
    }

    /// A bottle saved by another writer while a creation prepares its bottle (wineboot takes minutes) stays in
    /// the library: the creation registers its bottle in the library as it is then.
    @Test func aCreationKeepsABottleSavedWhileItPrepares() async throws {
        let (root, service) = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try fakeRuntime(service)
        try Data().write(to: service.paths.runtimeMarker)
        try FileManager.default.createDirectory(at: service.paths.libraries, withIntermediateDirectories: true)
        try Data().write(to: service.paths.libraries.appendingPathComponent("libinotify.0.dylib"))
        try service.paths.saveLibrary(Library())
        // The other writer's library, put in place whole while wineboot runs, as saveLibrary writes it.
        let other = Bottle(id: "other", name: "Other", launcher: nil, renderer: .dxmt)
        let otherLibrary = root.appendingPathComponent("other-library.json")
        try JSONEncoder().encode(Library(bottles: [other])).write(to: otherLibrary)
        let wine = service.paths.wine(for: .dxmt)
        let library = service.paths.library.path
        try fakeWine(wine)
        let script = try #require(contents(wine))
        try Data(script.replacingOccurrences(of: "#!/bin/sh\n", with: "#!/bin/sh\n[ \"$1\" = wineboot ] && cp '\(otherLibrary.path)' '\(library).new' && mv '\(library).new' '\(library)'\n").utf8).write(to: wine)
        let created = try await service.createBottle(name: "New", launcher: nil, renderer: .dxmt)
        #expect(Set(try service.library().bottles.map(\.id)) == ["other", created.id])
        // removeBottle tells a bottle from a later one at its id by this, so it survives the library's round trip.
        #expect(try service.bottle(created.id).createdAt == created.createdAt)
    }

    /// A removal of a bottle no longer listed (removed already), or listed as one created since at the same id,
    /// leaves the folder at that id, which may be the new creation's.
    @Test func aRepeatedRemovalLeavesTheFolderAlone() async throws {
        let (root, service) = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bottle = gtaBottle()
        let bottlePaths = try readyBottle(bottle, in: service)
        try service.paths.saveLibrary(Library())
        try await service.removeBottle(bottle)
        #expect(FileManager.default.fileExists(atPath: bottlePaths.marker.path))
        var recreated = bottle
        recreated.createdAt = Date()
        try service.paths.saveLibrary(Library(bottles: [recreated]))
        try await service.removeBottle(bottle)
        #expect(FileManager.default.fileExists(atPath: bottlePaths.marker.path))
        #expect(try service.library().bottles.map(\.id) == [bottle.id])
    }

    /// Entering keeps system32's originals once; a re-apply, or a repeated entry after a switch that did not
    /// finish, keeps them; leaving puts them back (repeatably) and removes what the bottle did not have.
    @Test func leavingTheProfilePutsSystem32Back() throws {
        let (root, service) = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bottlePaths = try readyBottle(gtaBottle(), in: service)
        let system32 = bottlePaths.drive.appendingPathComponent("windows/system32")
        let backup = service.engineBackup(of: .gta5Enhanced, in: bottlePaths)
        try service.applyFiles(of: .gta5Enhanced, to: bottlePaths)
        try service.applyFiles(of: .gta5Enhanced, to: bottlePaths)
        try service.applyFiles(of: .gta5Enhanced, to: bottlePaths)
        #expect(contents(system32.appendingPathComponent("d3d12.dll"))?.hasPrefix("profile:") == true)
        #expect(contents(system32.appendingPathComponent("dxgi.dll"))?.contains("launcher-wined3d") == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: backup.path).sorted() == [".names.json", "d3d10core.dll", "d3d11.dll", "dxgi.dll"])
        #expect(contents(backup.appendingPathComponent("dxgi.dll")) == "original:dxgi.dll")
        for _ in 0..<2 { try service.restoreFiles(of: .gta5Enhanced, to: bottlePaths) }
        for name in ["dxgi.dll", "d3d11.dll", "d3d10core.dll"] { #expect(contents(system32.appendingPathComponent(name)) == "original:\(name)") }
        for name in ["d3d12.dll", "atidxx64.dll"] { #expect(!FileManager.default.fileExists(atPath: system32.appendingPathComponent(name).path)) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: bottlePaths.drive.appendingPathComponent("Portnaut").path).allSatisfy { !$0.hasPrefix(".engine-backup") })
    }

    /// A bottle that entered when the profile copied other names (no d3d12.dll, an old.dll since dropped) gets
    /// a backup of today's names at the next apply: old.dll's original is back at once, and leaving puts back
    /// d3d12.dll's original, which the old backup never held.
    @Test func aChangedListOfCopiesTakesANewBackup() throws {
        let fm = FileManager.default
        let (root, service) = try scratchRoot()
        defer { try? fm.removeItem(at: root) }
        let bottlePaths = try readyBottle(gtaBottle(), in: service)
        let system32 = bottlePaths.drive.appendingPathComponent("windows/system32")
        let backup = service.engineBackup(of: .gta5Enhanced, in: bottlePaths)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        for name in ["dxgi.dll", "d3d11.dll", "d3d10core.dll"] { try fm.moveItem(at: system32.appendingPathComponent(name), to: backup.appendingPathComponent(name)) }
        try Data("original:old.dll".utf8).write(to: backup.appendingPathComponent("old.dll"))
        try Data(#"{"kept":["dxgi.dll","d3d11.dll","d3d10core.dll","old.dll"],"absent":["atidxx64.dll"]}"#.utf8).write(to: backup.appendingPathComponent(".names.json"))
        for name in ["dxgi.dll", "d3d11.dll", "d3d10core.dll", "old.dll", "atidxx64.dll"] { try Data("profile:old-list".utf8).write(to: system32.appendingPathComponent(name)) }
        try Data("original:d3d12.dll".utf8).write(to: system32.appendingPathComponent("d3d12.dll"))
        try service.applyFiles(of: .gta5Enhanced, to: bottlePaths)
        #expect(contents(system32.appendingPathComponent("old.dll")) == "original:old.dll")
        #expect(contents(system32.appendingPathComponent("d3d12.dll"))?.hasPrefix("profile:/") == true)
        #expect(contents(backup.appendingPathComponent("d3d12.dll")) == "original:d3d12.dll")
        #expect(!fm.fileExists(atPath: backup.appendingPathComponent("old.dll").path))
        let names = try JSONDecoder().decode(WineService.EngineBackupNames.self, from: Data(contentsOf: backup.appendingPathComponent(".names.json")))
        #expect(names == WineService.EngineBackupNames(kept: ["dxgi.dll", "d3d11.dll", "d3d12.dll", "d3d10core.dll"], absent: ["atidxx64.dll"]))
        try service.restoreFiles(of: .gta5Enhanced, to: bottlePaths)
        for name in ["dxgi.dll", "d3d11.dll", "d3d10core.dll", "d3d12.dll", "old.dll"] { #expect(contents(system32.appendingPathComponent(name)) == "original:\(name)") }
        #expect(!fm.fileExists(atPath: system32.appendingPathComponent("atidxx64.dll").path))
    }

    /// A backup taken before backups named what they cover (built here by hand, as gta5-enhanced took it then)
    /// holds the five names it copied then: leaving puts system32 back by them, and applying again names it.
    @Test(arguments: [false, true])
    func aBackupWithoutNamesCoversTheNamesCopiedThen(applyingAgain: Bool) throws {
        let fm = FileManager.default
        let (root, service) = try scratchRoot()
        defer { try? fm.removeItem(at: root) }
        let bottlePaths = try readyBottle(gtaBottle(), in: service)
        let system32 = bottlePaths.drive.appendingPathComponent("windows/system32")
        let backup = service.engineBackup(of: .gta5Enhanced, in: bottlePaths)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        for name in ["dxgi.dll", "d3d11.dll", "d3d10core.dll"] { try fm.moveItem(at: system32.appendingPathComponent(name), to: backup.appendingPathComponent(name)) }
        for name in ["dxgi.dll", "d3d11.dll", "d3d12.dll", "atidxx64.dll", "d3d10core.dll"] { try Data("profile:then".utf8).write(to: system32.appendingPathComponent(name)) }
        if applyingAgain {
            try service.applyFiles(of: .gta5Enhanced, to: bottlePaths)
            #expect(fm.fileExists(atPath: backup.appendingPathComponent(".names.json").path))
        }
        #expect(try service.engineBackupNames(of: .gta5Enhanced, in: bottlePaths) == WineService.EngineBackupNames(kept: ["dxgi.dll", "d3d11.dll", "d3d10core.dll"], absent: ["d3d12.dll", "atidxx64.dll"]))
        try service.restoreFiles(of: .gta5Enhanced, to: bottlePaths)
        for name in ["dxgi.dll", "d3d11.dll", "d3d10core.dll"] { #expect(contents(system32.appendingPathComponent(name)) == "original:\(name)") }
        for name in ["d3d12.dll", "atidxx64.dll"] { #expect(!fm.fileExists(atPath: system32.appendingPathComponent(name).path)) }
    }

    /// Names that contradict the backup's files (a kept original lost, an absent one held) stop leaving and
    /// applying again, so system32 keeps the profile's copies and the backup stays.
    @Test(arguments: ["lost", "held"])
    func aBackupThatContradictsItsNamesIsNotUsed(contradiction: String) throws {
        let fm = FileManager.default
        let (root, service) = try scratchRoot()
        defer { try? fm.removeItem(at: root) }
        let bottlePaths = try readyBottle(gtaBottle(), in: service)
        let system32 = bottlePaths.drive.appendingPathComponent("windows/system32")
        let backup = service.engineBackup(of: .gta5Enhanced, in: bottlePaths)
        try service.applyFiles(of: .gta5Enhanced, to: bottlePaths)
        switch contradiction {
        case "lost": try fm.removeItem(at: backup.appendingPathComponent("d3d11.dll"))
        default: try Data("stray".utf8).write(to: backup.appendingPathComponent("d3d12.dll"))
        }
        #expect(throws: PortnautError.self) { try service.restoreFiles(of: .gta5Enhanced, to: bottlePaths) }
        #expect(throws: PortnautError.self) { try service.applyFiles(of: .gta5Enhanced, to: bottlePaths) }
        #expect(contents(system32.appendingPathComponent("d3d11.dll"))?.contains("launcher-wined3d") == true)
        #expect(contents(system32.appendingPathComponent("dxgi.dll"))?.contains("launcher-wined3d") == true)
        #expect(contents(backup.appendingPathComponent("dxgi.dll")) == "original:dxgi.dll")
    }

    /// Through update(), as the Engine picker and `portnaut-doctor engine` switch: on, a re-save, then off,
    /// where the first try fails (Portnaut's Wine is missing) and is saved only when a retry applies.
    @Test func switchingTheEngineOnAndOffThroughUpdate() async throws {
        let (root, service) = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var bottle = gtaBottle()
        bottle.engineProfile = nil
        let bottlePaths = try readyBottle(bottle, in: service)
        let system32 = bottlePaths.drive.appendingPathComponent("windows/system32")
        let drive = bottlePaths.prefix.appendingPathComponent("dosdevices/y:")
        bottle.engineProfile = .gta5Enhanced
        try await service.update(bottle)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: drive.path) == service.paths.profile(.gta5Enhanced).root.path)
        bottle.highResolution.toggle()
        try await service.update(bottle)
        #expect(contents(service.engineBackup(of: .gta5Enhanced, in: bottlePaths).appendingPathComponent("dxgi.dll")) == "original:dxgi.dll")
        bottle.engineProfile = nil
        await #expect(throws: (any Error).self) { try await service.update(bottle) }
        #expect(try service.bottle(bottle.id).engineProfile == .gta5Enhanced)
        #expect(FileManager.default.fileExists(atPath: service.engineBackup(of: .gta5Enhanced, in: bottlePaths).path))
        try fakeRuntime(service)
        try await service.update(bottle)
        #expect(try service.bottle(bottle.id).engineProfile == nil)
        #expect(!FileManager.default.fileExists(atPath: service.engineBackup(of: .gta5Enhanced, in: bottlePaths).path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: drive.path) == service.paths.runtime.path)
        #expect(contents(system32.appendingPathComponent("dxgi.dll")) == "original:dxgi.dll")
        #expect(!FileManager.default.fileExists(atPath: system32.appendingPathComponent("d3d12.dll").path))
        let registry = try #require(contents(bottlePaths.drive.appendingPathComponent("Portnaut/profile.reg")))
        #expect(registry.contains(EngineProfile.gta5Enhanced.cleanupRegistry))
        #expect(!registry.contains("\"CaptureDisplaysForFullscreen\"=\"y\""))
        try await service.update(bottle)
        #expect(contents(bottlePaths.drive.appendingPathComponent("Portnaut/profile.reg"))?.contains("CaptureDisplaysForFullscreen") == false)
    }

    /// A preparation that failed after applying the profile (its registry import failed) leaves its files; once
    /// the bottle is switched off (update() only saves that for a bottle that is not ready), the next preparation
    /// takes them out.
    @Test func preparingAHalfPreparedBottleOffTheProfileLeavesIt() async throws {
        let (root, service) = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try fakeRuntime(service)
        var bottle = gtaBottle()
        let bottlePaths = try readyBottle(bottle, in: service)
        let system32 = bottlePaths.drive.appendingPathComponent("windows/system32")
        try FileManager.default.removeItem(at: bottlePaths.marker)
        let profileWine = service.paths.profile(.gta5Enhanced).engine.appendingPathComponent("bin/wine")
        try fakeWine(profileWine, failing: "reg")
        await #expect(throws: (any Error).self) { try await service.prepareBottle(bottle) }
        try fakeWine(profileWine)
        bottle.engineProfile = nil
        try await service.update(bottle)
        #expect(try service.bottle(bottle.id).engineProfile == nil)
        #expect(contents(system32.appendingPathComponent("d3d12.dll"))?.hasPrefix("profile:") == true)
        try await service.prepareBottle(bottle)
        #expect(bottlePaths.ready)
        for name in ["dxgi.dll", "d3d11.dll", "d3d10core.dll"] { #expect(contents(system32.appendingPathComponent(name)) == "original:\(name)") }
        #expect(!FileManager.default.fileExists(atPath: system32.appendingPathComponent("d3d12.dll").path))
        #expect(!FileManager.default.fileExists(atPath: service.engineBackup(of: .gta5Enhanced, in: bottlePaths).path))
        let registry = try #require(contents(bottlePaths.drive.appendingPathComponent("Portnaut/profile.reg")))
        #expect(registry.contains(EngineProfile.gta5Enhanced.cleanupRegistry))
    }

    /// A switch on that fails after copying the profile's files is not saved; switching off (a save with
    /// no profile) still finds the profile in the prefix by its backup and takes it out.
    @Test func aFailedSwitchOnIsUndoneBySwitchingOff() async throws {
        let (root, service) = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try fakeRuntime(service)
        var bottle = gtaBottle()
        bottle.engineProfile = nil
        let bottlePaths = try readyBottle(bottle, in: service)
        let system32 = bottlePaths.drive.appendingPathComponent("windows/system32")
        let profileWine = service.paths.profile(.gta5Enhanced).engine.appendingPathComponent("bin/wine")
        try fakeWine(profileWine, exitCode: 1)
        bottle.engineProfile = .gta5Enhanced
        await #expect(throws: (any Error).self) { try await service.update(bottle) }
        #expect(try service.bottle(bottle.id).engineProfile == nil)
        #expect(contents(system32.appendingPathComponent("d3d12.dll"))?.hasPrefix("profile:") == true)
        try fakeWine(profileWine)
        bottle.engineProfile = nil
        try await service.update(bottle)
        for name in ["dxgi.dll", "d3d11.dll", "d3d10core.dll"] { #expect(contents(system32.appendingPathComponent(name)) == "original:\(name)") }
        #expect(!FileManager.default.fileExists(atPath: system32.appendingPathComponent("d3d12.dll").path))
        #expect(!FileManager.default.fileExists(atPath: service.engineBackup(of: .gta5Enhanced, in: bottlePaths).path))
        #expect(contents(bottlePaths.drive.appendingPathComponent("Portnaut/profile.reg"))?.contains(EngineProfile.gta5Enhanced.cleanupRegistry) == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: bottlePaths.drive.appendingPathComponent("Portnaut/engine-backup").path).isEmpty)
    }

    /// A switch whose registry Wine's server never wrote to disk (killed before it exited) is not recorded as
    /// applied nor saved, whatever the import and the wait for the server returned; the next start repeats it.
    @Test func aSwitchIsRecordedOnlyOnceTheRegistryIsOnDisk() async throws {
        let (root, service) = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try fakeRuntime(service)
        var bottle = gtaBottle()
        bottle.engineProfile = nil
        let bottlePaths = try readyBottle(bottle, in: service)
        let profileServer = service.paths.profile(.gta5Enhanced).engine.appendingPathComponent("bin/wineserver")
        bottle.engineProfile = .gta5Enhanced
        for saved in [[], ["user.reg"], ["system.reg"]] {
            try fakeWine(profileServer, savedHives: saved)
            await #expect(throws: (any Error).self) { try await service.update(bottle) }
            #expect(try service.bottle(bottle.id).engineProfile == nil)
            #expect(try service.engineState(in: bottlePaths) == .changing(holding: .gta5Enhanced))
        }
        try fakeWine(profileServer)
        try await service.update(bottle)
        #expect(try service.bottle(bottle.id).engineProfile == .gta5Enhanced)
        #expect(try service.engineState(in: bottlePaths) == .applied(.gta5Enhanced, marker: EngineProfile.gta5Enhanced.marker))
    }

    /// An engine change while a Wine server runs in the prefix is refused before it touches anything; a settings
    /// save on the engine the prefix is on still imports into the running session.
    @Test func anEngineChangeWaitsForTheBottlesProgramsToQuit() async throws {
        let (root, service) = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try fakeRuntime(service)
        var bottle = gtaBottle()
        bottle.engineProfile = nil
        let bottlePaths = try readyBottle(bottle, in: service)
        try await service.update(bottle)
        #expect(try service.engineState(in: bottlePaths) == .applied(nil, marker: nil))
        let system32 = bottlePaths.drive.appendingPathComponent("windows/system32")
        var switched = bottle
        switched.engineProfile = .gta5Enhanced
        // 0: a server runs; anything but 0 or 1: the probe could not tell, which is not taken as "none".
        for status in [0, 2] {
            for renderer in Renderer.allCases { try fakeWine(service.paths.wineserver(for: renderer), probeStatus: status) }
            try fakeWine(service.paths.profile(.gta5Enhanced).engine.appendingPathComponent("bin/wineserver"), probeStatus: status)
            await #expect(throws: (any Error).self) { try await service.update(switched) }
            #expect(try service.engineState(in: bottlePaths) == .applied(nil, marker: nil))
            #expect(!FileManager.default.fileExists(atPath: system32.appendingPathComponent("d3d12.dll").path))
            #expect(try service.bottle(bottle.id).engineProfile == nil)
        }
        let imports = { (self.contents(bottlePaths.prefix.appendingPathComponent("reg-calls")) ?? "").split(separator: "\n").count }
        let importsBefore = imports()
        bottle.windowsVersion = .win7
        try await service.update(bottle)
        #expect(imports() == importsBefore + 1)
        #expect(try service.bottle(bottle.id).windowsVersion == .win7)
        #expect(contents(bottlePaths.drive.appendingPathComponent("Portnaut/profile.reg"))?.contains("\"Version\"=\"\(WindowsVersion.win7.rawValue)\"") == true)
    }

    /// Settings saved into a running session reach the prefix only when its server writes the hives, which a
    /// killed server never does; so every start Portnaut makes imports the saved bottle's registry profile
    /// again, on the engine the prefix is already on too.
    @Test func everyStartImportsTheSavedSettings() async throws {
        let (root, service) = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try fakeRuntime(service)
        try Data().write(to: service.paths.runtimeMarker)
        try FileManager.default.createDirectory(at: service.paths.libraries, withIntermediateDirectories: true)
        try Data().write(to: service.paths.libraries.appendingPathComponent("libinotify.0.dylib"))
        var bottle = gtaBottle()
        bottle.engineProfile = nil
        let bottlePaths = try readyBottle(bottle, in: service)
        try await service.update(bottle)
        bottle.windowsVersion = .win7
        try await service.update(bottle)
        let profile = bottlePaths.drive.appendingPathComponent("Portnaut/profile.reg")
        try FileManager.default.removeItem(at: profile)
        let imports = { (self.contents(bottlePaths.prefix.appendingPathComponent("reg-calls")) ?? "").split(separator: "\n").count }
        for _ in 0..<2 {
            let importsBefore = imports()
            try await service.requireEngine(of: bottle)
            #expect(imports() == importsBefore + 1)
        }
        #expect(contents(profile)?.contains("\"Version\"=\"\(WindowsVersion.win7.rawValue)\"") == true)
        // A start whose import fails does not go on with settings the prefix may not have.
        // The profile written again shows the start got as far as the import, the step that fails.
        try fakeWine(service.paths.wine(for: bottle.renderer), failing: "reg")
        try FileManager.default.removeItem(at: profile)
        await #expect(throws: (any Error).self) { try await service.requireEngine(of: bottle) }
        #expect(FileManager.default.fileExists(atPath: profile.path))
    }

    /// A managed start holds the bottle from its engine check until its program has run: an engine switch from
    /// elsewhere (another task here; the app and portnaut-doctor are separate processes) waits for the start's
    /// check and import (the gate), then refuses while the start's program may still be starting or running
    /// (the session). So a start never imports the leaving engine's values over a switch, nor runs the old Wine
    /// on a switched prefix.
    @Test func anEngineSwitchWaitsForAStartInProgress() async throws {
        let (root, service) = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try fakeRuntime(service)
        try Data().write(to: service.paths.runtimeMarker)
        try FileManager.default.createDirectory(at: service.paths.libraries, withIntermediateDirectories: true)
        try Data().write(to: service.paths.libraries.appendingPathComponent("libinotify.0.dylib"))
        var bottle = gtaBottle()
        bottle.engineProfile = nil
        let bottlePaths = try readyBottle(bottle, in: service)
        try await service.update(bottle)
        // The bottle's Wine stops, once armed, in a start's `reg import` (armed-reg) or in the program it runs
        // (armed-run) until the test lets it go, after telling the test it got there.
        let hold = root.appendingPathComponent("hold")
        try FileManager.default.createDirectory(at: hold, withIntermediateDirectories: true)
        for fifo in ["reached", "release"] { #expect(mkfifo(hold.appendingPathComponent(fifo).path, 0o600) == 0) }
        let wine = service.paths.wine(for: bottle)
        try FileManager.default.moveItem(at: wine, to: hold.appendingPathComponent("wine"))
        let script = "#!/bin/sh\nH='\(hold.path)'\n"
            + "case \"$1\" in reg) step=reg ;; wineboot|cmd) step= ;; *) step=run ;; esac\n"
            + "if [ -n \"$step\" ] && [ -e \"$H/armed-$step\" ]; then rm \"$H/armed-$step\"; echo reached > \"$H/reached\"; read go < \"$H/release\"; fi\n"
            + "exec \"$H/wine\" \"$@\"\n"
        try Data(script.utf8).write(to: wine)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        let reached = hold.appendingPathComponent("reached").path, release = hold.appendingPathComponent("release").path
        let contentions = Recorded()
        let first = FirstEvent()
        service.lockContended = { kind in contentions.append(kind.rawValue); first.signal("contended \(kind.rawValue)") }
        var switched = bottle
        switched.engineProfile = .gta5Enhanced

        try Data().write(to: hold.appendingPathComponent("armed-reg"))
        let start = Task { try await service.requireEngine(of: bottle) }
        await arrival(at: reached, of: start)
        // The switch either finds the start's lock held, or runs to its end without waiting for the start.
        let change = Task {
            defer { first.signal("switch ended") }
            try await service.update(switched)
        }
        #expect(await first.value == "contended gate")
        await onThread { FileHandle(forWritingAtPath: release).map { $0.write(Data("go\n".utf8)); $0.closeFile() } }
        let session = try await start.value
        let refused = await #expect(throws: PortnautError.self) { try await change.value }
        #expect(refused?.message.hasPrefix("Quit the Windows programs") == true)
        #expect(contentions.values == ["gate", "session"])
        #expect(try service.engineState(in: bottlePaths) == .applied(nil, marker: nil))
        #expect(try service.bottle(bottle.id).engineProfile == nil)
        session.release()

        // A start through run holds the session while its program runs.
        let program = bottlePaths.drive.appendingPathComponent("game.exe")
        try Data().write(to: program)
        try Data().write(to: hold.appendingPathComponent("armed-run"))
        let launch = Task { try await service.run(program, in: bottle, waitForSession: false) }
        await arrival(at: reached, of: launch)
        let busy = await #expect(throws: PortnautError.self) { try await service.update(switched) }
        #expect(busy?.message.hasPrefix("Quit the Windows programs") == true)
        await onThread { FileHandle(forWritingAtPath: release).map { $0.write(Data("go\n".utf8)); $0.closeFile() } }
        _ = try await launch.value
        #expect(try service.engineState(in: bottlePaths) == .applied(nil, marker: nil))

        // Once the start's program has run, the switch goes through.
        try await service.update(switched)
        #expect(try service.engineState(in: bottlePaths) == .applied(.gta5Enhanced, marker: EngineProfile.gta5Enhanced.marker))
    }

    /// A game's per-program keys outlive the game in the prefix unless Portnaut removes them: imports empty them
    /// for each program it wrote them for that is no longer a game, until the user hive on disk holds the stamp
    /// of an import that emptied them (an older one's too; one a killed server never saved does not count);
    /// then the program is left alone, so keys set up by hand afterwards stay. A program that becomes a game
    /// again, under another case too, gets its settings back.
    @Test func aRemovedGamesProgramKeysAreEmptied() async throws {
        let (root, service) = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try fakeRuntime(service)
        try Data().write(to: service.paths.runtimeMarker)
        try FileManager.default.createDirectory(at: service.paths.libraries, withIntermediateDirectories: true)
        try Data().write(to: service.paths.libraries.appendingPathComponent("libinotify.0.dylib"))
        var bottle = gtaBottle()
        bottle.engineProfile = nil
        let bottlePaths = try readyBottle(bottle, in: service)
        var game = Game(id: "old", name: "Old", executable: "Games/Old/Old.exe")
        game.dllOverrides = ["d3d9": .native]
        bottle.games = [game]
        try await service.update(bottle)
        let profile = bottlePaths.drive.appendingPathComponent("Portnaut/profile.reg")
        let userHive = bottlePaths.prefix.appendingPathComponent("user.reg")
        let key = "HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\Old.exe"
        let emptied = "[-\(key)\\DllOverrides]\n[\(key)]\n\"Version\"=-"
        let empties = { self.contents(profile)?.contains(emptied) == true }
        let lastStamp = {
            let text = self.contents(profile) ?? ""
            return text.range(of: "\"EmptiedStamp\"=\"").map { String(text[$0.upperBound...].prefix { $0 != "\"" }) }
        }
        // The server saving the session: the user hive on disk with `stamp`, and a Version for the program set
        // by hand (winecfg) after its keys were emptied.
        let save = { (stamp: String?) in
            let hive = "[Software\\\\Portnaut] 1732238400\n\"EmptiedStamp\"=\"\(stamp ?? "")\"\n\n"
                + "[Software\\\\Wine\\\\AppDefaults\\\\Old.exe] 1732238400\n\"Version\"=\"win7\"\n"
            try Data(hive.utf8).write(to: userHive)
        }
        #expect(contents(profile)?.contains("[\(key)\\DllOverrides]\n\"d3d9\"=\"native\"") == true)
        #expect(lastStamp() == nil)
        try service.removeGame(game, from: bottle)
        bottle.games = []
        // Not saved yet: every import empties the keys again, its stamp after them.
        try await service.requireEngine(of: bottle)
        #expect(empties())
        let first = lastStamp()
        #expect(first != nil && contents(profile)!.range(of: emptied)!.upperBound < contents(profile)!.range(of: "\"EmptiedStamp\"")!.lowerBound)
        try await service.requireEngine(of: bottle)
        #expect(empties())
        #expect(lastStamp() != first)
        // Saved after the first of them: the next import leaves the program, and the hand-set Version, alone.
        try save(first)
        try await service.requireEngine(of: bottle)
        #expect(!empties())
        #expect(lastStamp() == nil)

        // Removed again; an import fails and Wine saves nothing of it: the next one empties.
        bottle.games = [game]
        try await service.update(bottle)
        try service.removeGame(game, from: bottle)
        bottle.games = []
        let wine = service.paths.wine(for: bottle.renderer)
        try fakeWine(wine, failing: "reg")
        await #expect(throws: (any Error).self) { try await service.requireEngine(of: bottle) }
        try fakeWine(wine)
        try await service.requireEngine(of: bottle)
        #expect(empties())

        // Still being emptied, it becomes a game again under another case, the same program to Wine: it gets
        // its settings and nothing empties them.
        game.executable = "Games/Old/OLD.EXE"
        bottle.games = [game]
        try await service.update(bottle)
        #expect(contents(profile)?.contains("[HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\OLD.EXE\\DllOverrides]\n\"d3d9\"=\"native\"") == true)
        #expect(contents(profile)?.contains("[-\(key)\\DllOverrides]") == false)
        #expect(lastStamp() == nil)
    }

    /// The emptied stamp is read from Portnaut's own key in the user hive as Wine writes it, whole.
    @Test func theEmptiedStampIsReadFromTheUserHive() {
        let hive = """
        [Software\\\\Portnaut\\\\Other] 1
        "EmptiedStamp"="other"

        [Software\\\\Portnaut] 1
        "EngineStamp"="engine"
        "EmptiedStamp"="saved"

        """
        #expect(WineService.savedEmptiedStamp(inUserHive: hive) == "saved")
        #expect(WineService.savedEmptiedStamp(inUserHive: "[Software\\\\Portnaut\\\\Other] 1\n\"EmptiedStamp\"=\"other\"\n") == nil)
        #expect(WineService.savedEmptiedStamp(inUserHive: "[Software\\\\Portnaut] 1\n\"EmptiedStamp\"=\"saved\n") == nil)
        #expect(WineService.savedEmptiedStamp(inUserHive: "") == nil)
    }

    /// Letting go of a bottle lock frees it even while another reference to its open file shares the lock: a
    /// process another thread spawns holds a copy of every descriptor from its fork until its exec closes the
    /// close-on-exec ones, and a close alone would leave the lock held until then. A dup stands in for that copy.
    @Test func aReleasedBottleLockIsFreeWhileASpawningChildSharesIt() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("portnaut-lock-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let descriptor = open(file.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        try #require(descriptor >= 0)
        let lock = WineService.BottleLock(descriptor: descriptor)
        try #require(flock(descriptor, LOCK_EX) == 0)
        let copy = dup(descriptor)
        try #require(copy >= 0)
        defer { close(copy) }
        lock.release()
        let next = open(file.path, O_RDWR | O_CLOEXEC)
        try #require(next >= 0)
        defer { close(next) }
        let status = flock(next, LOCK_EX | LOCK_NB), error = errno
        #expect(status == 0, "the lock is still held through the copy (errno \(error))")
    }

    /// Waits until the armed Wine reports, through the FIFO at `reached`, that it got to its stop; a `task`
    /// that fails before that writes to the FIFO itself, so the wait ends and the test fails on the task.
    func arrival<T: Sendable>(at reached: String, of task: Task<T, any Error>) async {
        let watcher = Task {
            if case .failure = await task.result {
                await onThread { FileHandle(forWritingAtPath: reached).map { $0.write(Data("failed\n".utf8)); $0.closeFile() } }
            }
        }
        let report = Recorded()
        await onThread { report.append(String(decoding: FileHandle(forReadingAtPath: reached)?.readDataToEndOfFile() ?? Data(), as: UTF8.self)) }
        #expect(report.values == ["reached\n"], "the task ended before its Wine reached the stop")
        _ = watcher
    }

    /// Values appended from any thread.
    final class Recorded: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func append(_ value: String) { lock.lock(); stored.append(value); lock.unlock() }
        var values: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    /// Runs blocking work (a FIFO's open, which waits for the other end; FileHandle opens it so, String(contentsOf:)
    /// does not) on a thread of its own, off the cooperative pool.
    func onThread(_ body: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread { body(); done.resume() }
        }
    }

    /// The first of several events to happen; later ones are ignored.
    final class FirstEvent: @unchecked Sendable {
        private let lock = NSLock()
        private var event: String?
        private var waiter: CheckedContinuation<String, Never>?
        func signal(_ name: String) {
            lock.lock()
            guard event == nil else { return lock.unlock() }
            event = name
            let waiting = waiter
            waiter = nil
            lock.unlock()
            waiting?.resume(returning: name)
        }
        var value: String {
            get async {
                await withCheckedContinuation { continuation in
                    lock.lock()
                    if let event { lock.unlock(); continuation.resume(returning: event) } else { waiter = continuation; lock.unlock() }
                }
            }
        }
    }

    /// Where a switch can fail part-way, and how to make it fail there and undo that.
    enum SwitchFailure: CaseIterable {
        case driveY, files, registry, save

        func inject(_ service: WineService, _ bottlePaths: BottlePaths, wine: URL) throws {
            switch self {
            case .driveY: try lock(bottlePaths.prefix.appendingPathComponent("dosdevices"), true)
            case .files: try lock(bottlePaths.drive.appendingPathComponent("windows/system32"), true)
            case .registry: try EngineProfileTests().fakeWine(wine, exitCode: 1)
            case .save: try lock(service.paths.root, true)
            }
        }
        func undo(_ service: WineService, _ bottlePaths: BottlePaths, wine: URL) throws {
            switch self {
            case .driveY: try lock(bottlePaths.prefix.appendingPathComponent("dosdevices"), false)
            case .files: try lock(bottlePaths.drive.appendingPathComponent("windows/system32"), false)
            case .registry: try EngineProfileTests().fakeWine(wine)
            case .save: try lock(service.paths.root, false)
            }
        }
        func lock(_ folder: URL, _ locked: Bool) throws {
            try FileManager.default.setAttributes([.posixPermissions: locked ? 0o555 : 0o755], ofItemAtPath: folder.path)
        }
    }

    /// The prefix is on `profile`'s engine (nil: Portnaut's): drive Y:, system32 and the registry profile.
    func expectOnEngine(_ profile: EngineProfile?, _ service: WineService, _ bottlePaths: BottlePaths) throws {
        let system32 = bottlePaths.drive.appendingPathComponent("windows/system32")
        let drive = bottlePaths.prefix.appendingPathComponent("dosdevices/y:")
        let registry = contents(bottlePaths.drive.appendingPathComponent("Portnaut/profile.reg")) ?? ""
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: drive.path) == (profile.map { service.paths.profile($0).root } ?? service.paths.runtime).path)
        if profile == nil {
            for name in ["dxgi.dll", "d3d11.dll", "d3d10core.dll"] { #expect(contents(system32.appendingPathComponent(name)) == "original:\(name)") }
            #expect(!FileManager.default.fileExists(atPath: system32.appendingPathComponent("d3d12.dll").path))
            #expect(!registry.contains("\"CaptureDisplaysForFullscreen\"=\"y\""))
        } else {
            #expect(contents(system32.appendingPathComponent("dxgi.dll"))?.contains("launcher-wined3d") == true)
            #expect(contents(system32.appendingPathComponent("d3d12.dll"))?.hasPrefix("profile:") == true)
            // The profile's values come last, after a game's; an engine change's stamp follows in its own key.
            let values = registry.components(separatedBy: "[HKEY_CURRENT_USER\\Software\\Portnaut]")[0]
            #expect(values.hasSuffix(EngineProfile.gta5Enhanced.registry))
        }
    }

    /// An engine switch that fails at any step leaves the saved choice as it was, and the next program start
    /// brings the prefix back to that engine; choosing that engine again is no change, so nothing else does.
    @Test(arguments: SwitchFailure.allCases, [false, true])
    func aStartAfterAFailedSwitchIsOnTheSavedEngine(failure: SwitchFailure, switchingOn: Bool) async throws {
        let (root, service) = try scratchRoot()
        defer {
            try? failure.undo(service, service.paths.bottle(gtaBottle()), wine: service.paths.wine(for: .d3dmetal))
            try? FileManager.default.removeItem(at: root)
        }
        try fakeRuntime(service)
        try Data().write(to: service.paths.runtimeMarker)
        try FileManager.default.createDirectory(at: service.paths.libraries, withIntermediateDirectories: true)
        try Data().write(to: service.paths.libraries.appendingPathComponent("libinotify.0.dylib"))
        var bottle = gtaBottle()
        bottle.engineProfile = nil
        let bottlePaths = try readyBottle(bottle, in: service)
        let program = bottlePaths.drive.appendingPathComponent("game.exe")
        try Data().write(to: program)
        let from: EngineProfile? = switchingOn ? nil : .gta5Enhanced
        let to: EngineProfile? = switchingOn ? .gta5Enhanced : nil
        if !switchingOn {
            bottle.engineProfile = .gta5Enhanced
            try await service.update(bottle)
        }
        // The Wine of the engine the bottle switches to imports the registry.
        let wine = switchingOn ? service.paths.profile(.gta5Enhanced).engine.appendingPathComponent("bin/wine") : service.paths.wine(for: .d3dmetal)
        try failure.inject(service, bottlePaths, wine: wine)
        bottle.engineProfile = to
        await #expect(throws: (any Error).self) { try await service.update(bottle) }
        try failure.undo(service, bottlePaths, wine: wine)
        #expect(try service.bottle(bottle.id).engineProfile == from)
        bottle.engineProfile = from
        try await service.launch(program, in: bottle, waitForSession: false)
        try expectOnEngine(from, service, bottlePaths)
    }

    /// A bottle set up on the profile before engine records existed (its backup there, no record) is switched
    /// off through update() before any start: the profile's files and values still go.
    @Test func aBottleFromBeforeRecordsLeavesTheProfile() async throws {
        let (root, service) = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try fakeRuntime(service)
        var bottle = gtaBottle()
        let bottlePaths = try readyBottle(bottle, in: service)
        try service.mapRuntimeDrive(bottlePaths, to: service.paths.profile(.gta5Enhanced).root)
        try service.applyFiles(of: .gta5Enhanced, to: bottlePaths)
        bottle.engineProfile = nil
        try await service.update(bottle)
        try expectOnEngine(nil, service, bottlePaths)
        #expect(contents(bottlePaths.drive.appendingPathComponent("Portnaut/profile.reg"))?.contains(EngineProfile.gta5Enhanced.cleanupRegistry) == true)
        #expect(!FileManager.default.fileExists(atPath: service.engineBackup(of: .gta5Enhanced, in: bottlePaths).path))
    }

    /// A start with a bottle whose engine is not the saved one is refused, so no other engine's Wine runs on the
    /// prefix; a drive Y: pointing elsewhere under a matching record is pointed at the engine again.
    @Test func aStartChecksTheCallersEngineAndDriveY() async throws {
        let (root, service) = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try fakeRuntime(service)
        try Data().write(to: service.paths.runtimeMarker)
        try FileManager.default.createDirectory(at: service.paths.libraries, withIntermediateDirectories: true)
        try Data().write(to: service.paths.libraries.appendingPathComponent("libinotify.0.dylib"))
        let bottle = gtaBottle()
        let bottlePaths = try readyBottle(bottle, in: service)
        let program = bottlePaths.drive.appendingPathComponent("game.exe")
        try Data().write(to: program)
        try await service.update(bottle)
        var stale = bottle
        stale.engineProfile = nil
        await #expect(throws: PortnautError.self) { try await service.launch(program, in: stale, waitForSession: false) }
        try service.mapRuntimeDrive(bottlePaths, to: root.appendingPathComponent("elsewhere"))
        try await service.launch(program, in: bottle, waitForSession: false)
        try expectOnEngine(.gta5Enhanced, service, bottlePaths)
    }

    /// A bottle whose files came from an earlier build of its profile (a record with another marker, or one
    /// written before records kept markers) gets the current build's files at its next start, recorded with
    /// that build's marker only once its registry is on disk.
    @Test(arguments: [nil, "gta5-enhanced-v2:old"] as [String?])
    func aStartAfterAProfileRebuildCopiesItsFilesAgain(oldMarker: String?) async throws {
        let (root, service) = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try fakeRuntime(service)
        try Data().write(to: service.paths.runtimeMarker)
        try FileManager.default.createDirectory(at: service.paths.libraries, withIntermediateDirectories: true)
        try Data().write(to: service.paths.libraries.appendingPathComponent("libinotify.0.dylib"))
        let bottle = gtaBottle()
        let bottlePaths = try readyBottle(bottle, in: service)
        let program = bottlePaths.drive.appendingPathComponent("game.exe")
        try Data().write(to: program)
        try await service.update(bottle)
        let d3d12 = bottlePaths.drive.appendingPathComponent("windows/system32/d3d12.dll")
        // The bottle as the earlier build left it: its d3d12 and its record.
        try Data("earlier build".utf8).write(to: d3d12)
        let old = try #require(String(data: JSONEncoder().encode(EngineState.applied(.gta5Enhanced, marker: oldMarker)), encoding: .utf8))
        if oldMarker == nil { #expect(!old.contains("marker")) }
        try Data(old.utf8).write(to: service.engineStateFile(in: bottlePaths))
        #expect(try !service.engineInPlace(for: bottle))
        let profileServer = service.paths.profile(.gta5Enhanced).engine.appendingPathComponent("bin/wineserver")
        try fakeWine(profileServer, savedHives: [])
        await #expect(throws: PortnautError.self) { try await service.launch(program, in: bottle, waitForSession: false) }
        #expect(try service.engineState(in: bottlePaths) == .changing(holding: .gta5Enhanced))
        #expect(contents(d3d12)?.hasPrefix("profile:") == true)
        // The repeat copies the files again, whatever the failed attempt left.
        try Data("earlier build".utf8).write(to: d3d12)
        try fakeWine(profileServer)
        try await service.launch(program, in: bottle, waitForSession: false)
        #expect(contents(d3d12)?.hasPrefix("profile:") == true)
        // The originals kept when the bottle first entered the profile stay the originals.
        let backup = service.engineBackup(of: .gta5Enhanced, in: bottlePaths)
        for name in ["dxgi.dll", "d3d11.dll", "d3d10core.dll"] { #expect(contents(backup.appendingPathComponent(name)) == "original:\(name)") }
        #expect(!FileManager.default.fileExists(atPath: backup.appendingPathComponent("d3d12.dll").path))
        #expect(try service.engineState(in: bottlePaths) == .applied(.gta5Enhanced, marker: EngineProfile.gta5Enhanced.marker))
        #expect(try service.engineInPlace(for: bottle))
    }

    /// Every value the profile writes is removed by its cleanup, which comes before the bottle's own values.
    @Test func cleanupRemovesEveryProfileValueAndKeepsTheBottlesOwn() {
        func values(_ registry: String) -> Set<String> {
            var section = "", found = Set<String>()
            for line in registry.split(separator: "\n") {
                if line.hasPrefix("[") { section = String(line) }
                else if line.hasPrefix("\""), let end = line.dropFirst().firstIndex(of: "\"") { found.insert(section + line[...end]) }
            }
            return found
        }
        let profile = EngineProfile.gta5Enhanced
        #expect(values(profile.cleanupRegistry) == values(profile.registry))
        #expect(profile.cleanupRegistry.split(separator: "\n").filter { $0.hasPrefix("\"") }.allSatisfy { $0.hasSuffix("=-") })
        var bottle = gtaBottle()
        bottle.engineProfile = nil
        var game = Game(id: "gta5", name: "GTA V Enhanced", executable: EngineProfile.gameFolder + "/GTA5_Enhanced.exe")
        game.dllOverrides = ["dxgi": .native]
        bottle.games = [game]
        let registry = WineService.profile(for: bottle, leaving: profile)
        let removed = registry.range(of: "\"dxgi\"=-")
        let restored = registry.range(of: "\"dxgi\"=\"native\"")
        #expect(removed != nil && restored != nil && removed!.lowerBound < restored!.lowerBound)
        let socialClub = registry.range(of: "\"CommandLineAppend\"=\"")
        #expect(socialClub != nil && removed!.lowerBound < socialClub!.lowerBound)
        #expect(registry.hasPrefix("Windows Registry Editor Version 5.00\n\n" + profile.cleanupRegistry))
    }

    /// Restoring a snapshot of a profile bottle points drive Y: at the profile again.
    @Test func restoringAProfileSnapshotPointsDriveYAtTheProfile() async throws {
        let (root, service) = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bottlePaths = try readyBottle(gtaBottle(), in: service)
        let snapshot = try service.takeSnapshot(of: gtaBottle(), label: "On the profile")
        var plain = gtaBottle()
        plain.engineProfile = nil
        try service.save(plain)
        try service.mapRuntimeDrive(bottlePaths, to: service.paths.runtime)
        try await service.restoreSnapshot(snapshot, of: plain)
        #expect(try service.bottle(plain.id).engineProfile == .gta5Enhanced)
        let drive = bottlePaths.prefix.appendingPathComponent("dosdevices/y:")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: drive.path) == service.paths.profile(.gta5Enhanced).root.path)
    }

    /// A profile that cannot be built stops the restore before the bottle changes.
    @Test func restoringAProfileSnapshotWithoutTheProfileChangesNothing() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("portnaut-engine-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let service = WineService(paths: PortnautPaths(root: root), metalShim: nil)
        try service.paths.createDirectories()
        let bottlePaths = try readyBottle(gtaBottle(), in: service)
        let snapshot = try service.takeSnapshot(of: gtaBottle(), label: "On the profile")
        var plain = gtaBottle()
        plain.engineProfile = nil
        try service.save(plain)
        let sentinel = bottlePaths.drive.appendingPathComponent("after-snapshot.txt")
        try Data("kept".utf8).write(to: sentinel)
        // Downloads is a file, so building the profile fails before anything is fetched.
        try fm.removeItem(at: service.paths.cache)
        try Data().write(to: service.paths.cache)
        await #expect(throws: (any Error).self) { try await service.restoreSnapshot(snapshot, of: plain) }
        #expect(contents(sentinel) == "kept")
        #expect(try service.bottle(plain.id).engineProfile == nil)
        #expect(service.snapshots(of: plain).count == 1)
    }

    @Test func aProfileBottleHasNoBestSetup() {
        let game = Game(id: "gta5", name: "GTA V Enhanced", executable: EngineProfile.gameFolder + "/GTA5_Enhanced.exe")
        let service = WineService(paths: PortnautPaths(root: URL(fileURLWithPath: "/tmp/portnaut-root")), metalShim: nil)
        #expect(throws: PortnautError.self) { try service.startSetupTrial(for: game, in: gtaBottle()) }
    }
}
