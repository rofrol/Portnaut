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
        #expect(final["d3d12.dll"] == "/p/packs/apple-d3dmetal-4.0b2/wine/x86_64-windows/d3d12.dll")
        #expect(final["atidxx64.dll"] == "/p/deps/Frameworks/renderer/d3dmetal/wine/x86_64-windows/atidxx64.dll")
    }

    @Test func linksResolveInsideTheProfile() {
        #expect(EngineProfile.linkTarget("renderer/d3dmetal/wine/x86_64-windows/dxgi.dll") { _ in true }
                == "packs/apple-d3dmetal-4.0b2/wine/x86_64-windows/dxgi.dll")
        #expect(EngineProfile.linkTarget("renderer/d3dmetal/wine/x86_64-windows/atidxx64.dll") { _ in false }
                == "deps/Frameworks/renderer/d3dmetal/wine/x86_64-windows/atidxx64.dll")
        #expect(EngineProfile.linkTarget("libfreetype.6.dylib") { _ in true } == "deps/Frameworks/libfreetype.6.dylib")
        // D3DMetal 4.0b2's pack has the Unix side but no atidxx64.dll; that one comes from the template.
        let pack: Set = ["external/libd3dshared.dylib", "wine/x86_64-windows/d3d11.dll"]
        let targets = Dictionary(uniqueKeysWithValues: EngineProfile.engineLinks.map { ($0.link, EngineProfile.linkTarget($0.target) { pack.contains($0) }) })
        #expect(targets["lib/wine/x86_64-unix/d3d12.so"] == "packs/apple-d3dmetal-4.0b2/external/libd3dshared.dylib")
        #expect(targets["lib/wine/x86_64-windows/atidxx64.dll"] == "deps/Frameworks/renderer/d3dmetal/wine/x86_64-windows/atidxx64.dll")
        // The game gets D3DMetal's dxgi from the engine's own folder, which Wine searches before WINEDLLPATH.
        let pack2: Set = ["external/libd3dshared.dylib", "wine/x86_64-windows/dxgi.dll"]
        #expect(EngineProfile.engineLinks.first { $0.link == "lib/wine/x86_64-windows/dxgi.dll" }
                    .map { EngineProfile.linkTarget($0.target) { pack2.contains($0) } } == "packs/apple-d3dmetal-4.0b2/wine/x86_64-windows/dxgi.dll")
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
    /// A Wine that exits with `exitCode`, or fails only the `failing` command (as `reg`).
    func fakeWine(_ url: URL, exitCode: Int = 0, failing: String? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // wineboot creates the folders prepareBottle's later steps use.
        let wineboot = "[ \"$1\" = wineboot ] && mkdir -p \"$WINEPREFIX/dosdevices\" \"$WINEPREFIX/drive_c/windows/system32\"\n"
        let failure = failing.map { "[ \"$1\" = \($0) ] && exit 1\n" } ?? ""
        try Data("#!/bin/sh\n\(wineboot)\(failure)exit \(exitCode)\n".utf8).write(to: url)
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
        #expect(try FileManager.default.contentsOfDirectory(atPath: backup.path).sorted() == ["d3d10core.dll", "d3d11.dll", "dxgi.dll"])
        #expect(contents(backup.appendingPathComponent("dxgi.dll")) == "original:dxgi.dll")
        for _ in 0..<2 { try service.restoreFiles(of: .gta5Enhanced, to: bottlePaths) }
        for name in ["dxgi.dll", "d3d11.dll", "d3d10core.dll"] { #expect(contents(system32.appendingPathComponent(name)) == "original:\(name)") }
        for name in ["d3d12.dll", "atidxx64.dll"] { #expect(!FileManager.default.fileExists(atPath: system32.appendingPathComponent(name).path)) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: bottlePaths.drive.appendingPathComponent("Portnaut").path).allSatisfy { !$0.hasPrefix(".engine-backup") })
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
            #expect(registry.hasSuffix(EngineProfile.gta5Enhanced.registry))
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
