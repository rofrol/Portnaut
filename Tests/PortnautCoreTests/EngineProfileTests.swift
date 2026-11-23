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
    /// exits with `probeStatus` (0: a server runs, 1: none). With `calls`, each run appends a line there: its first
    /// argument and whether each of `probeLocks` was held then (`held`, `free`, `missing`, or `error` when flock
    /// failed otherwise). With `users`, each run appends its first argument, USER and LOGNAME there; wineboot also
    /// sets up USER's folder in drive_c/users, as Wine does for a user the prefix has not seen.
    func fakeWine(_ url: URL, exitCode: Int = 0, failing: String? = nil, savedHives: [String] = ["user.reg", "system.reg"], probeStatus: Int = 1,
                  calls: URL? = nil, probeLocks: [URL] = [], users: URL? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // wineboot creates the folders prepareBottle's later steps use.
        let wineboot = "[ \"$1\" = wineboot ] && mkdir -p \"$WINEPREFIX/dosdevices\" \"$WINEPREFIX/drive_c/windows/system32\"\n"
            + (users == nil ? "" : "[ \"$1\" = wineboot ] && mkdir -p \"$WINEPREFIX/drive_c/users/$USER\"\n")
        let failure = failing.map { "[ \"$1\" = \($0) ] && exit 1\n" } ?? ""
        let probe = "[ \"$1\" = -k0 ] && exit \(probeStatus)\n"
        let profile = "\"$WINEPREFIX/drive_c/Portnaut/profile.reg\""
        let keep = { (root: String, hive: String) in
            "grep -F -A1 '[\(root)\\Software\\Portnaut]' \(profile) | grep '\"EngineStamp\"' >> \"$WINEPREFIX/in-memory.\(hive)\""
        }
        let registry = "[ \"$1\" = reg ] && { echo reg >> \"$WINEPREFIX/reg-calls\"; \(keep("HKEY_CURRENT_USER", "user.reg")); \(keep("HKEY_LOCAL_MACHINE", "system.reg")); }\n"
            + "[ \"$1\" = -w ] && { for hive in \(savedHives.joined(separator: " ")); do cat \"$WINEPREFIX/in-memory.$hive\" >> \"$WINEPREFIX/$hive\" 2>/dev/null; done; rm -f \"$WINEPREFIX\"/in-memory.*; }\n"
        let lockStates = #"perl -MFcntl=:flock -e 'for (@ARGV) { if (open(my $f, "<", $_)) { print flock($f, LOCK_SH | LOCK_NB) ? " free" : $!{EWOULDBLOCK} ? " held" : " error" } else { print " missing" } }'"#
            + probeLocks.map { " '\($0.path)'" }.joined()
        let record = calls.map { "{ printf %s \"$1\"; \(lockStates); echo; } >> '\($0.path)'\n" } ?? ""
        let user = users.map { "echo \"$1 $USER $LOGNAME\" >> '\($0.path)'\n" } ?? ""
        try Data("#!/bin/sh\n\(record)\(user)\(wineboot)\(probe)\(failure)\(registry)exit \(exitCode)\n".utf8).write(to: url)
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

    // MARK: - Windows user

    /// A Portnaut runtime and profile whose Wine records each run's USER and LOGNAME in the returned file.
    func fakeEnginesRecordingUsers(_ root: URL, _ service: WineService) throws -> URL {
        let users = root.appendingPathComponent("users.log")
        for renderer in Renderer.allCases {
            try fakeWine(service.paths.wine(for: renderer), users: users)
            try fakeWine(service.paths.wineserver(for: renderer))
        }
        try fakeWine(service.paths.profile(.gta5Enhanced).engine.appendingPathComponent("bin/wine"), users: users)
        try Data().write(to: service.paths.runtimeMarker)
        try FileManager.default.createDirectory(at: service.paths.libraries, withIntermediateDirectories: true)
        try Data().write(to: service.paths.libraries.appendingPathComponent("libinotify.0.dylib"))
        return users
    }
    func userFolders(_ bottlePaths: BottlePaths) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: bottlePaths.drive.appendingPathComponent("users").path)) ?? []).sorted()
    }

    /// A bottle born on either engine and switched to the other and back runs every Wine of both as the Windows user
    /// it was born with (crossover on the profile, the Mac user on Portnaut's Wine), so its programs' data stays in
    /// the one user folder it has.
    @Test(arguments: [nil, .gta5Enhanced] as [EngineProfile?])
    func aBottleRunsAsTheUserItWasBornWithOnEveryEngine(born: EngineProfile?) async throws {
        let (root, service) = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let users = try fakeEnginesRecordingUsers(root, service)
        let macUser = try #require(ProcessInfo.processInfo.environment["USER"])
        #expect(macUser != "crossover")
        let expected = born == nil ? macUser : "crossover"
        var bottle = try await service.createBottle(name: "Rockstar Games Launcher", launcher: .rockstar, renderer: .dxmt, engineProfile: born)
        let bottlePaths = service.paths.bottle(bottle)
        #expect(contents(service.windowsUserFile(in: bottlePaths)) == expected + "\n")
        for profile in [born == nil ? .gta5Enhanced : nil, born] {
            bottle.engineProfile = profile
            try await service.update(bottle)
            #expect(try service.bottle(bottle.id).engineProfile == profile)
            try await service.requireEngine(of: bottle)
            #expect(service.environment(for: bottle)["USER"] == expected)
        }
        let runs = (contents(users) ?? "").split(separator: "\n").map { $0.split(separator: " ").map(String.init) }
        // wineboot, then each engine's registry imports.
        #expect(runs.count >= 5)
        #expect(runs.first?.first == "wineboot")
        for run in runs { #expect(Array(run.dropFirst()) == [expected, expected], "\(run)") }
        #expect(userFolders(bottlePaths) == [expected])
    }

    /// A prefix from before pins with one user folder is pinned to it at its next start, whatever its engine's user.
    @Test func aStartPinsThePrefixsOnlyUser() async throws {
        let (root, service) = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let users = try fakeEnginesRecordingUsers(root, service)
        let bottle = gtaBottle()
        let bottlePaths = try readyBottle(bottle, in: service)
        for name in ["alice", "Public", ".hidden"] {
            try FileManager.default.createDirectory(at: bottlePaths.drive.appendingPathComponent("users/\(name)"), withIntermediateDirectories: true)
        }
        try Data().write(to: bottlePaths.drive.appendingPathComponent("users/notes.txt"))
        #expect(service.environment(for: bottle)["LOGNAME"] == "alice")
        try await service.requireEngine(of: bottle)
        #expect(contents(service.windowsUserFile(in: bottlePaths)) == "alice\n")
        #expect(contents(users)?.split(separator: "\n").allSatisfy { $0.hasSuffix(" alice alice") } == true)
    }

    /// A prefix with several user folders and no pin (switched between engines before pins existed) is refused
    /// before any Wine runs in it, until the user pins one; a pin that is not a single name is refused too.
    @Test func aPrefixWhoseUserCannotBeToldIsRefused() async throws {
        let (root, service) = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let users = try fakeEnginesRecordingUsers(root, service)
        var bottle = gtaBottle()
        bottle.engineProfile = nil
        let bottlePaths = try readyBottle(bottle, in: service)
        for name in ["crossover", "romanfrolow"] {
            try FileManager.default.createDirectory(at: bottlePaths.drive.appendingPathComponent("users/\(name)"), withIntermediateDirectories: true)
        }
        let pin = service.windowsUserFile(in: bottlePaths)
        try await expectRefusal(naming: "crossover, romanfrolow") { try await service.requireEngine(of: bottle) }
        bottle.engineProfile = .gta5Enhanced
        try await expectRefusal(naming: "crossover, romanfrolow") { try await service.update(bottle) }
        #expect(try service.bottle(bottle.id).engineProfile == nil)
        #expect(!FileManager.default.fileExists(atPath: pin.path))
        #expect(try service.engineState(in: bottlePaths) == nil)
        #expect(contents(users) == nil)
        try FileManager.default.createDirectory(at: pin.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Each would run Wine as a user with empty folders: a typo, spaces, Public, two names, a path, a control.
        for bad in ["", "\n", "\n\n", "crossvoer\n", " crossover\n", "crossover \n", "Public\n", "crossover\nromanfrolow\n",
                    "crossover\r\n", "a/crossover", "..\n", "a\\crossover\n", "cross\u{0}over\n"] {
            try Data(bad.utf8).write(to: pin)
            try await expectRefusal(naming: "does not name one of") { try await service.update(bottle) }
        }
        #expect(contents(users) == nil)
        try Data("crossover\n".utf8).write(to: pin)
        try await service.update(bottle)
        #expect(try service.bottle(bottle.id).engineProfile == .gta5Enhanced)
        #expect(contents(users)?.split(separator: "\n").allSatisfy { $0.hasSuffix(" crossover crossover") } == true)
    }

    func expectRefusal(naming text: String, _ body: () async throws -> Void) async throws {
        do {
            try await body()
            Issue.record("no refusal")
        } catch let error as PortnautError {
            #expect(error.message.contains(text), "\(error.message)")
        }
    }

    /// A pin that is not one name is refused also while the prefix has no user folder to check it against, and a
    /// prefix's only user folder is not pinned when its name is not one.
    @Test func aPinOrFolderThatIsNotOneNameIsRefused() async throws {
        let (root, service) = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let users = try fakeEnginesRecordingUsers(root, service)
        let bottle = gtaBottle()
        let bottlePaths = try readyBottle(bottle, in: service)
        let pin = service.windowsUserFile(in: bottlePaths)
        try FileManager.default.createDirectory(at: pin.deletingLastPathComponent(), withIntermediateDirectories: true)
        for bad in ["", " alice\n", "Public\n", "alice\nbob\n", "a/alice", ".alice\n", "al\u{0}ice\n", "al\tice\n", "a\\alice\n"] {
            try Data(bad.utf8).write(to: pin)
            try await expectRefusal(naming: "does not name one of") { try await service.requireEngine(of: bottle) }
        }
        try FileManager.default.removeItem(at: pin)
        try FileManager.default.createDirectory(at: bottlePaths.drive.appendingPathComponent("users/alice "), withIntermediateDirectories: true)
        try await expectRefusal(naming: "is not a name") { try await service.requireEngine(of: bottle) }
        #expect(!FileManager.default.fileExists(atPath: pin.path))
        #expect(contents(users) == nil)
    }

    /// A user folder that is a link to a folder elsewhere is the prefix's user; a lowercase public is not one; a link
    /// that leads nowhere now (a volume not mounted) still counts, so the prefix's other folder is not taken for it.
    @Test func aLinkedUserFolderIsThePrefixsUser() async throws {
        let (root, service) = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try fakeEnginesRecordingUsers(root, service)
        let bottle = gtaBottle()
        let bottlePaths = try readyBottle(bottle, in: service)
        let users = bottlePaths.drive.appendingPathComponent("users")
        let elsewhere = root.appendingPathComponent("elsewhere/alice")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: users.appendingPathComponent("public"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: users.appendingPathComponent("alice"), withDestinationURL: elsewhere)
        try await service.requireEngine(of: bottle)
        #expect(contents(service.windowsUserFile(in: bottlePaths)) == "alice\n")

        var other = Bottle(id: "other", name: "Other", launcher: .rockstar, renderer: .d3dmetal)
        other.engineProfile = .gta5Enhanced
        let otherPaths = try readyBottle(other, in: service)
        let otherUsers = otherPaths.drive.appendingPathComponent("users")
        try FileManager.default.createDirectory(at: otherUsers.appendingPathComponent("crossover"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: otherUsers.appendingPathComponent("bob"), withDestinationURL: root.appendingPathComponent("unmounted/bob"))
        // A link to a file is no user's folder, so the refusal does not list it.
        let notes = root.appendingPathComponent("notes.txt")
        try Data().write(to: notes)
        try FileManager.default.createSymbolicLink(at: otherUsers.appendingPathComponent("notes"), withDestinationURL: notes)
        try await expectRefusal(naming: "folders for bob, crossover, and") { try await service.requireEngine(of: other) }
        #expect(!FileManager.default.fileExists(atPath: service.windowsUserFile(in: otherPaths).path))
    }

    /// The pin outlasts a user the bottle's own variables set: Wine sets up that user's folder while the variable
    /// applies, and once it is gone the bottle runs as its pinned user again instead of being refused.
    @Test func aUserSetInTheBottlesVariablesLeavesThePinnedOne() async throws {
        let (root, service) = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try fakeEnginesRecordingUsers(root, service)
        var bottle = gtaBottle()
        let bottlePaths = try readyBottle(bottle, in: service)
        try FileManager.default.createDirectory(at: bottlePaths.drive.appendingPathComponent("users/alice"), withIntermediateDirectories: true)
        try await service.requireEngine(of: bottle)
        bottle.environment = ["USER": "tester"]
        try await service.update(bottle)
        #expect(service.environment(for: bottle)["USER"] == "tester")
        try FileManager.default.createDirectory(at: bottlePaths.drive.appendingPathComponent("users/tester"), withIntermediateDirectories: true)
        bottle.environment = [:]
        try await service.update(bottle)
        try await service.requireEngine(of: bottle)
        #expect(service.environment(for: bottle)["USER"] == "alice")
        #expect(contents(service.windowsUserFile(in: bottlePaths)) == "alice\n")
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

    /// A ready bottle to switch on (off Portnaut's engine onto the profile) or off (already on the profile).
    /// Its d3d10core.dll original is a symbolic link to elsewhere.dll, which the profile does not touch; its
    /// d3d12.dll and atidxx64.dll originals are absent. Returns the root, the bottle's paths and a program.
    func switchScenario(switchingOn: Bool) async throws -> (URL, WineService, BottlePaths, URL) {
        let fm = FileManager.default
        let (root, service) = try scratchRoot()
        try fakeRuntime(service)
        try Data().write(to: service.paths.runtimeMarker)
        try fm.createDirectory(at: service.paths.libraries, withIntermediateDirectories: true)
        try Data().write(to: service.paths.libraries.appendingPathComponent("libinotify.0.dylib"))
        var bottle = gtaBottle()
        bottle.engineProfile = nil
        let bottlePaths = try readyBottle(bottle, in: service)
        let system32 = bottlePaths.drive.appendingPathComponent("windows/system32")
        try fm.removeItem(at: system32.appendingPathComponent("d3d10core.dll"))
        try Data("original:d3d10core.dll".utf8).write(to: system32.appendingPathComponent("elsewhere.dll"))
        try fm.createSymbolicLink(atPath: system32.appendingPathComponent("d3d10core.dll").path, withDestinationPath: "elsewhere.dll")
        let program = bottlePaths.drive.appendingPathComponent("game.exe")
        try Data().write(to: program)
        if !switchingOn {
            bottle.engineProfile = .gta5Enhanced
            try await service.update(bottle)
        }
        return (root, service, bottlePaths, program)
    }

    /// The bottle is whole on the engine its saved choice names: expectOnEngine, the record, the symbolic link
    /// original kept as a link (in system32 off the profile, in the backup on it), and no leftovers of a change.
    /// Off the profile, a backup may remain (a leave stopped after its record said applied); it holds no
    /// originals, so entering and leaving again must give the same originals back. On the profile, leaving
    /// must give them back from the backup.
    func expectRecovered(_ service: WineService, _ bottlePaths: BottlePaths, _ context: String) async throws {
        try expectWhole(service, bottlePaths, context)
        var bottle = try service.bottle(gtaBottle().id)
        if bottle.engineProfile == nil {
            bottle.engineProfile = .gta5Enhanced
            try await service.update(bottle)
            try expectWhole(service, bottlePaths, context + ", entered again")
        }
        bottle.engineProfile = nil
        try await service.update(bottle)
        try expectWhole(service, bottlePaths, context + ", left")
        #expect(!FileManager.default.fileExists(atPath: service.engineBackup(of: .gta5Enhanced, in: bottlePaths).path), "\(context)")
    }
    func expectWhole(_ service: WineService, _ bottlePaths: BottlePaths, _ context: String) throws {
        let fm = FileManager.default
        let saved = try service.bottle(gtaBottle().id).engineProfile
        try expectOnEngine(saved, service, bottlePaths)
        #expect(try service.engineState(in: bottlePaths) == .applied(saved, marker: saved?.marker), "\(context)")
        let link = saved == nil
            ? bottlePaths.drive.appendingPathComponent("windows/system32/d3d10core.dll")
            : service.engineBackup(of: .gta5Enhanced, in: bottlePaths).appendingPathComponent("d3d10core.dll")
        #expect((try? fm.destinationOfSymbolicLink(atPath: link.path)) == "elsewhere.dll", "\(context)")
        if let saved {
            #expect(try service.engineBackupNames(of: saved, in: bottlePaths)?.all == Set(saved.systemNames(layout: service.paths.profile(saved))), "\(context)")
            #expect(contents(bottlePaths.drive.appendingPathComponent("windows/system32/d3d10core.dll"))?.contains("launcher-wined3d") == true, "\(context)")
        }
        let left = try fm.contentsOfDirectory(atPath: bottlePaths.drive.appendingPathComponent("Portnaut").path)
        #expect(left.allSatisfy { !$0.hasPrefix(".engine-backup-") && !$0.contains(Durable.temporaryMark) }, "\(context): \(left)")
    }

    /// Ends this process with exit code `code` at the change's `n`th step (barriers are not counted); with
    /// `expected`, only when that step is the one named, and with `StepStop.otherStep` when another one is there.
    final class StepStop: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        let n: Int, code: Int32, expected: String?
        static let otherStep: Int32 = 44
        init(at n: Int, expecting expected: String? = nil, code: Int32) { self.n = n; self.expected = expected; self.code = code }
        func reach(_ step: String) {
            guard !step.hasPrefix("sync:") else { return }
            lock.lock(); count += 1; let reached = count == n; lock.unlock()
            if reached { _exit(expected.map { $0 == step } ?? true ? code : Self.otherStep) }
        }
    }

    /// Run in an exit test's own process: the switch through update(), or (`recovering`) a start of the saved
    /// engine, stopped like a crash (_exit: no defers, no catch) at its `n`th step, `expected`, with exit code `code`.
    static func runInterrupted(root: URL, switchingOn: Bool, recovering: Bool, at n: Int, expecting expected: String, code: Int32) async throws {
        let service = WineService(paths: PortnautPaths(root: root), metalShim: nil)
        let stop = StepStop(at: n, expecting: expected, code: code)
        service.engineStep = { stop.reach($0) }
        var bottle = try service.bottle(EngineProfileTests().gtaBottle().id)
        if recovering {
            try await service.launch(service.paths.bottle(bottle).drive.appendingPathComponent("game.exe"), in: bottle, waitForSession: false)
        } else {
            bottle.engineProfile = switchingOn ? .gta5Enhanced : nil
            try await service.update(bottle)
        }
    }

    /// What a crash test interrupts: a switch onto the profile or off it through update(), or a start that applies
    /// the profile again over a backup covering other names than the profile copies now (applyFiles' changed-names
    /// branch: the old backup's originals go back and it is discarded before a new one is taken).
    enum EngineChange: CaseIterable, Sendable { case switchingOn, switchingOff, changedNames }

    /// A ready bottle set up for `change`, as switchScenario. For changedNames the bottle is on the profile from an
    /// earlier build, whose list lacked d3d10core.dll: its backup covers the other four names, d3d10core.dll's
    /// original (the link) is in system32, and its record names an older marker, so the next start applies it again.
    func changeScenario(_ change: EngineChange) async throws -> (URL, WineService, BottlePaths, URL) {
        guard change == .changedNames else { return try await switchScenario(switchingOn: change == .switchingOn) }
        let fm = FileManager.default
        let (root, service, bottlePaths, program) = try await switchScenario(switchingOn: false)
        do {
            let backup = service.engineBackup(of: .gta5Enhanced, in: bottlePaths)
            let system32 = bottlePaths.drive.appendingPathComponent("windows/system32")
            var covered = try #require(try service.engineBackupNames(of: .gta5Enhanced, in: bottlePaths))
            try fm.removeItem(at: system32.appendingPathComponent("d3d10core.dll"))
            try fm.moveItem(at: backup.appendingPathComponent("d3d10core.dll"), to: system32.appendingPathComponent("d3d10core.dll"))
            covered.kept.removeAll { $0 == "d3d10core.dll" }
            #expect(covered.all == ["dxgi.dll", "d3d11.dll", "d3d12.dll", "atidxx64.dll"])
            try JSONEncoder().encode(covered).write(to: backup.appendingPathComponent(WineService.engineBackupNamesFile))
            try service.writeEngineState(.applied(.gta5Enhanced, marker: "gta5-enhanced-v2:earlier"), in: bottlePaths)
        } catch {
            try? fm.removeItem(at: root)
            throw error
        }
        return (root, service, bottlePaths, program)
    }

    /// cloneRoot for an engine crash test. Drive Y: is a link holding an absolute path into `root`; it is pointed at
    /// the same place in the clone, or the clone's start would find drive Y: elsewhere and change the engine where a
    /// start of `root` would not.
    func cloneEngineRoot(_ root: URL) throws -> URL {
        let fm = FileManager.default
        let copy = try cloneRoot(root)
        do {
            let drive = PortnautPaths(root: copy).bottle(gtaBottle()).prefix.appendingPathComponent("dosdevices/y:")
            if let target = try? fm.destinationOfSymbolicLink(atPath: drive.path), target.hasPrefix(root.path + "/") {
                try fm.removeItem(at: drive)
                try fm.createSymbolicLink(atPath: drive.path, withDestinationPath: copy.path + target.dropFirst(root.path.count))
            }
        } catch {
            try? fm.removeItem(at: copy)
            throw error
        }
        return copy
    }

    /// The program the crash tests start, in the bottle of the root `service` works on.
    func game(_ service: WineService) -> URL { service.paths.bottle(gtaBottle()).drive.appendingPathComponent("game.exe") }

    /// An engine change stopped like a crash at any of its steps (between an unlink and its copy, around the
    /// backup's publication and retirement, each record write, the save), and the start that recovers it stopped
    /// once more at one of its own steps, ends at the next clean start whole on the saved engine, with every
    /// original's bytes, absence and link target. This test stops each recovery at one step, the one whose name it
    /// stopped least often so far (the later one on a tie), so the recoveries' steps are spread over the first
    /// crashes; the matrix below stops each recovery at every one. Power loss itself is not reproduced; the
    /// barriers' order is checked below.
    @Test(arguments: EngineChange.allCases)
    func anEngineChangeCrashedAtAnyStepEndsWholeOnTheSavedEngine(_ change: EngineChange) async throws {
        try await crashEngineChange(change, stoppingEveryRecoveryStep: false)
    }

    /// Every (first crash, second crash) pair of crashEngineChange: each recovery stopped at each of its own steps.
    /// A child process per pair, about seven minutes on an M1 Pro (measured 2026-11-23: 406 s and 442 s for the three cases), so
    /// it runs only when asked: `PORTNAUT_CRASH_MATRIX=1 bash scripts/test.sh --filter AndItsRecoveryAtAnyOfItsOwn`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PORTNAUT_CRASH_MATRIX"] == "1"), arguments: EngineChange.allCases)
    func anEngineChangeCrashedAtAnyStepAndItsRecoveryAtAnyOfItsOwnEndsWholeOnTheSavedEngine(_ change: EngineChange) async throws {
        try await crashEngineChange(change, stoppingEveryRecoveryStep: true)
    }

    /// Stops `change` at each of its steps in a child process (exit 42), as a crash does (_exit: no defers, no catch
    /// blocks that clean up). The recovery's steps are counted on an APFS clone of what that crash left; each second
    /// crash (all of them, or one per first crash) runs a child recovery on a clone of its own, stopped at its mth
    /// step (exit 43, and only at the step counted there: StepStop.otherStep otherwise), then a clean start. The
    /// crashed root itself recovers in-process, unstopped, through the steps the clone counted.
    func crashEngineChange(_ change: EngineChange, stoppingEveryRecoveryStep: Bool) async throws {
        let fm = FileManager.default
        let (dryRoot, dryService, _, _) = try await changeScenario(change)
        defer { try? fm.removeItem(at: dryRoot) }
        let recorded = Recorded()
        dryService.engineStep = { if !$0.hasPrefix("sync:") { recorded.append($0) } }
        var dryBottle = try dryService.bottle(gtaBottle().id)
        let from = dryBottle.engineProfile
        switch change {
        case .switchingOn, .switchingOff:
            dryBottle.engineProfile = change == .switchingOn ? .gta5Enhanced : nil
            try await dryService.update(dryBottle)
        case .changedNames:
            try await dryService.launch(game(dryService), in: dryBottle, waitForSession: false)
        }
        let to = dryBottle.engineProfile
        let steps = recorded.values
        try #require(steps.contains("record:changing") && steps.contains("record:applied"), "\(steps)")
        switch change {
        case .switchingOn: #expect(steps.contains("backup:publish"))
        case .switchingOff: #expect(steps.contains("backup:discard"))
        case .changedNames:
            // The old backup's originals go back, then it goes, then the new one is taken.
            let restored = try #require(steps.lastIndex { $0.hasPrefix("restore:copy:") }, "\(steps)")
            let discard = try #require(steps.firstIndex(of: "backup:discard"), "\(steps)")
            let publish = try #require(steps.firstIndex(of: "backup:publish"), "\(steps)")
            #expect(restored < discard && discard < publish, "\(steps)")
        }
        // The `save` step comes before the save: a change stopped after it has the new choice saved.
        let save = try #require(steps.firstIndex(of: "save"), "\(steps)")
        // Children run a few at a time, each on its own clone; the cases of a test run side by side.
        let width = max(1, ProcessInfo.processInfo.activeProcessorCount / EngineChange.allCases.count)
        var stopped: [String: Int] = [:]
        for index in steps.indices {
            let n = index + 1, step = steps[index]
            let (root, _, bottlePaths, _) = try await changeScenario(change)
            defer { try? fm.removeItem(at: root) }
            let first = "\(change): stopped at step \(n), \(step)"
            let on = change == .switchingOn, start = change == .changedNames
            try await #require(processExitsWith: .exitCode(42), "\(first)") { [root = root as URL, on = on as Bool, start = start as Bool, n = n as Int, step = step as String] in
                try await EngineProfileTests.runInterrupted(root: root, switchingOn: on, recovering: start, at: n, expecting: step, code: 42)
            }
            // The choice saved when the change stopped; recovery brings the bottle to it and never changes it.
            let chosen = try WineService(paths: PortnautPaths(root: root), metalShim: nil).bottle(gtaBottle().id).engineProfile
            #expect(chosen == (index > save ? to : from), "\(first)")
            let dry = try cloneEngineRoot(root)
            defer { try? fm.removeItem(at: dry) }
            let dryRecovery = WineService(paths: PortnautPaths(root: dry), metalShim: nil)
            let counted = Recorded()
            dryRecovery.engineStep = { if !$0.hasPrefix("sync:") { counted.append($0) } }
            try await dryRecovery.launch(game(dryRecovery), in: try dryRecovery.bottle(gtaBottle().id), waitForSession: false)
            let recoverySteps = counted.values
            let stops: [Int]
            if stoppingEveryRecoveryStep || recoverySteps.isEmpty {
                stops = recoverySteps.indices.map { $0 + 1 }
            } else {
                let least = recoverySteps.indices.reversed().min { stopped[recoverySteps[$0], default: 0] < stopped[recoverySteps[$1], default: 0] }!
                stopped[recoverySteps[least], default: 0] += 1
                stops = [least + 1]
            }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (started, m) in stops.enumerated() {
                    if started >= width { try await group.next() }
                    let copy = try cloneEngineRoot(root)
                    let second = recoverySteps[m - 1]
                    let context = "\(first), recovery stopped at step \(m), \(second)"
                    group.addTask {
                        defer { try? FileManager.default.removeItem(at: copy) }
                        try await #require(processExitsWith: .exitCode(43), "\(context)") { [copy = copy as URL, m = m as Int, second = second as String] in
                            try await EngineProfileTests.runInterrupted(root: copy, switchingOn: false, recovering: true, at: m, expecting: second, code: 43)
                        }
                        let fresh = WineService(paths: PortnautPaths(root: copy), metalShim: nil)
                        try await fresh.launch(game(fresh), in: try fresh.bottle(gtaBottle().id), waitForSession: false)
                        #expect(try fresh.bottle(gtaBottle().id).engineProfile == chosen, "\(context)")
                        try await expectRecovered(fresh, fresh.paths.bottle(gtaBottle()), context)
                    }
                }
                try await group.waitForAll()
            }
            let fresh = WineService(paths: PortnautPaths(root: root), metalShim: nil)
            let own = Recorded()
            fresh.engineStep = { if !$0.hasPrefix("sync:") { own.append($0) } }
            try await fresh.launch(game(fresh), in: try fresh.bottle(gtaBottle().id), waitForSession: false)
            fresh.engineStep = nil
            #expect(own.values == recoverySteps, "\(first): the clone counted the steps the crashed root takes")
            #expect(try fresh.bottle(gtaBottle().id).engineProfile == chosen, "\(first)")
            try await expectRecovered(fresh, bottlePaths, first)
        }
    }

    /// Each step an engine change relies on is durable before it: the `changing` record before the prefix
    /// changes, a new backup in place before system32 changes, the originals before their backup goes, and
    /// drive Y:, system32 and both hives before the record says applied, which is durable before the backup
    /// of the profile left goes. (Power loss is not reproducible in a test; this checks the barriers' order.)
    @Test(arguments: [true, false])
    func anEngineChangeIsDurableBeforeTheStepsThatRelyOnIt(switchingOn: Bool) async throws {
        let (root, service, bottlePaths, _) = try await switchScenario(switchingOn: switchingOn)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorded = Recorded()
        service.engineStep = { recorded.append($0) }
        var bottle = try service.bottle(gtaBottle().id)
        bottle.engineProfile = switchingOn ? .gta5Enhanced : nil
        try await service.update(bottle)
        let steps = recorded.values
        let portnaut = bottlePaths.drive.appendingPathComponent("Portnaut")
        let system32 = bottlePaths.drive.appendingPathComponent("windows/system32")
        func index(_ step: String, after start: Int = -1) throws -> Int {
            try #require(steps.indices.first { $0 > start && steps[$0] == step }, "\(step) after \(start): \(steps)")
        }
        let changing = try index("record:changing")
        let recordWritten = try index("sync:" + portnaut.path, after: changing)
        #expect(try recordWritten < index("drive"))
        #expect(steps[changing..<recordWritten].contains { $0.hasPrefix("sync:" + portnaut.path + "/.engine-state.json" + Durable.temporaryMark) })
        #expect(steps[..<changing].contains("sync:" + bottlePaths.drive.path))
        let applied = try index("record:applied")
        let beforeApplied = Set(steps[..<applied])
        for url in [system32, bottlePaths.prefix.appendingPathComponent("dosdevices/y:"), bottlePaths.prefix.appendingPathComponent("dosdevices"),
                    bottlePaths.prefix.appendingPathComponent("user.reg"), bottlePaths.prefix.appendingPathComponent("system.reg"), bottlePaths.prefix] {
            #expect(beforeApplied.contains("sync:" + url.path), "\(url.path)")
        }
        if switchingOn {
            let publish = try index("backup:publish")
            let firstUnlink = try #require(steps.firstIndex { $0.hasPrefix("system32:unlink:") })
            #expect(try index("sync:" + service.engineBackup(of: .gta5Enhanced, in: bottlePaths).deletingLastPathComponent().path, after: publish) < firstUnlink)
            let staged = steps[..<publish].filter { $0.hasPrefix("sync:" + portnaut.path + "/.engine-backup-") }
            #expect(staged.contains { $0.hasSuffix("/" + WineService.engineBackupNamesFile) })
            for name in ["dxgi.dll", "d3d11.dll", "d3d10core.dll"] { #expect(staged.contains { $0.hasSuffix("/" + name) }, "\(name)") }
            #expect(staged.contains { !$0.dropFirst("sync:".count + portnaut.path.count + 1).contains("/") }, "the stage folder itself")
            for folder in [service.engineBackup(of: .gta5Enhanced, in: bottlePaths).deletingLastPathComponent(), portnaut, bottlePaths.drive] {
                #expect(try index("sync:" + folder.path, after: publish) < firstUnlink, "\(folder.path)")
            }
            // A replay over a backup already in place makes it durable again before system32 changes.
            let replay = Recorded()
            service.engineStep = { replay.append($0) }
            try service.applyFiles(of: .gta5Enhanced, to: bottlePaths)
            let replayed = replay.values
            #expect(!replayed.contains("backup:publish"))
            let replayUnlink = try #require(replayed.firstIndex { $0.hasPrefix("system32:unlink:") })
            for folder in [service.engineBackup(of: .gta5Enhanced, in: bottlePaths).deletingLastPathComponent(), portnaut, bottlePaths.drive] {
                #expect(replayed[..<replayUnlink].contains("sync:" + folder.path), "\(folder.path)")
            }
            for copy in EngineProfile.gta5Enhanced.systemCopies(layout: service.paths.profile(.gta5Enhanced)) {
                #expect(beforeApplied.contains("sync:" + system32.appendingPathComponent(copy.name).path), "\(copy.name)")
            }
        } else {
            let discard = try index("backup:discard")
            #expect(try index("sync:" + portnaut.path, after: applied) < discard)
            #expect(steps[..<discard].contains("sync:" + system32.path))
            let backups = service.engineBackup(of: .gta5Enhanced, in: bottlePaths).deletingLastPathComponent()
            #expect(try index("sync:" + backups.path, after: discard) < (try index("backup:remove")))
            for name in ["dxgi.dll", "d3d11.dll", "d3d10core.dll"] {
                #expect(steps[..<discard].contains("sync:" + system32.appendingPathComponent(name).path), "\(name)")
            }
        }
    }

    /// What a crash leaves does not stay: a start after a leave stopped mid-restore (a truncated original in
    /// system32), with a backup stage holding a truncated copy and writeDurably's temporary file beside the
    /// record, restores the originals whole and removes the stage and the file; a `.discarded-*` folder stays.
    @Test func aStartAfterACrashRemovesWhatTheCrashLeft() async throws {
        let fm = FileManager.default
        let (root, service, bottlePaths, program) = try await switchScenario(switchingOn: false)
        defer { try? fm.removeItem(at: root) }
        var bottle = try service.bottle(gtaBottle().id)
        bottle.engineProfile = nil
        try service.save(bottle)
        try service.writeEngineState(.changing(holding: .gta5Enhanced), in: bottlePaths)
        try Data("origin".utf8).write(to: bottlePaths.drive.appendingPathComponent("windows/system32/dxgi.dll"))
        let portnaut = bottlePaths.drive.appendingPathComponent("Portnaut")
        let stage = portnaut.appendingPathComponent(".engine-backup-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        try Data("orig".utf8).write(to: stage.appendingPathComponent("d3d11.dll"))
        try Data("{\"app".utf8).write(to: portnaut.appendingPathComponent(".engine-state.json" + Durable.temporaryMark + UUID().uuidString))
        let discarded = service.engineBackup(of: .gta5Enhanced, in: bottlePaths).deletingLastPathComponent().appendingPathComponent(".discarded-earlier")
        try fm.createDirectory(at: discarded, withIntermediateDirectories: true)
        try await service.launch(program, in: bottle, waitForSession: false)
        try await expectRecovered(service, bottlePaths, "after a crash mid-restore")
        #expect(fm.fileExists(atPath: discarded.path))
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

    /// A prepared bottle off the profile with a snapshot, and a file written after the snapshot, which a restore
    /// that did not happen leaves in place.
    func restorableBottle(_ service: WineService) async throws -> (Bottle, BottlePaths, Snapshot, URL) {
        try fakeRuntime(service)
        try Data().write(to: service.paths.runtimeMarker)
        try FileManager.default.createDirectory(at: service.paths.libraries, withIntermediateDirectories: true)
        try Data().write(to: service.paths.libraries.appendingPathComponent("libinotify.0.dylib"))
        var bottle = gtaBottle()
        bottle.engineProfile = nil
        let bottlePaths = try readyBottle(bottle, in: service)
        try await service.update(bottle)
        let snapshot = try service.takeSnapshot(of: bottle, label: "Earlier")
        let sentinel = bottlePaths.drive.appendingPathComponent("after-snapshot.txt")
        try Data("kept".utf8).write(to: sentinel)
        return (bottle, bottlePaths, snapshot, sentinel)
    }

    /// A start that has checked the engine but not yet started its program holds the session: a restore refuses
    /// then, rather than waiting for a program the user may keep open while every other start waits on the gate.
    @Test func aRestoreRefusesWhileAStartHoldsTheSession() async throws {
        let (root, service) = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (bottle, _, snapshot, sentinel) = try await restorableBottle(service)
        let session = try await service.requireEngine(of: bottle)
        let first = FirstEvent()
        service.lockContended = { kind in first.signal("contended \(kind.rawValue)") }
        let restore = Task {
            defer { first.signal("restore ended") }
            try await service.restoreSnapshot(snapshot, of: bottle)
        }
        #expect(await first.value == "contended session")
        // A restore that waits for the session goes on once the start lets it go.
        session.release()
        let refused = await #expect(throws: PortnautError.self) { try await restore.value }
        #expect(refused?.message.hasPrefix("Quit the Windows programs") == true)
        #expect(contents(sentinel) == "kept")
        #expect(service.snapshots(of: bottle).count == 1)
    }

    /// A Wine server still running after the stop (a stop that failed, or a launcher's children no managed start
    /// holds the session for) makes the restore refuse before the prefix changes.
    @Test func aRestoreRefusesWhileAWineServerRuns() async throws {
        let (root, service) = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (bottle, _, snapshot, sentinel) = try await restorableBottle(service)
        try fakeWine(service.paths.wineserver(for: bottle), probeStatus: 0)
        let refused = await #expect(throws: PortnautError.self) { try await service.restoreSnapshot(snapshot, of: bottle) }
        #expect(refused?.message.hasPrefix("Quit the Windows programs") == true)
        #expect(contents(sentinel) == "kept")
        #expect(service.snapshots(of: bottle).count == 1)
    }

    /// A snapshot that cannot be cloned leaves the current prefix in place, and no partial clone beside it.
    @Test func aRestoreThatCannotCloneKeepsThePrefix() async throws {
        let (root, service) = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (bottle, bottlePaths, snapshot, sentinel) = try await restorableBottle(service)
        // clonefile needs to read the whole tree: a folder no one may read makes it fail with EACCES.
        let unreadable = service.paths.snapshots(of: bottle).appendingPathComponent(snapshot.id).appendingPathComponent("prefix/unreadable")
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
        #expect(chmod(unreadable.path, 0) == 0)
        defer { chmod(unreadable.path, 0o755) }
        await #expect(throws: PortnautError.self) { try await service.restoreSnapshot(snapshot, of: bottle) }
        #expect(contents(sentinel) == "kept")
        #expect(bottlePaths.ready)
        #expect((try? FileManager.default.attributesOfItem(atPath: service.paths.bottles.appendingPathComponent(".\(bottle.id).restoring").path)) == nil)
    }

    /// A restore cancelled while it waits for the gate changes nothing once it gets the gate.
    @Test func aRestoreCancelledWhileWaitingForTheGateChangesNothing() async throws {
        let (root, service) = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (bottle, _, snapshot, sentinel) = try await restorableBottle(service)
        let gate = try await service.waitForLock(.gate, of: bottle, exclusive: true)
        let first = FirstEvent()
        service.lockContended = { kind in first.signal("contended \(kind.rawValue)") }
        let restore = Task {
            defer { first.signal("restore ended") }
            try await service.restoreSnapshot(snapshot, of: bottle)
        }
        #expect(await first.value == "contended gate")
        restore.cancel()
        gate.release()
        await #expect(throws: CancellationError.self) { try await restore.value }
        #expect(contents(sentinel) == "kept")
        #expect(service.snapshots(of: bottle).count == 1)
    }

    /// Records, when the restore reaches `step` (as it replaces the bottle's files), the bottle's wineserver runs so
    /// far (each with the gate's and the session's state then), then whether each of the bottle's locks could
    /// be taken from a descriptor of its own.
    func watchRestore(_ service: WineService, of bottle: Bottle, at step: String) throws -> Recorded {
        let calls = service.paths.root.appendingPathComponent("wineserver-calls")
        let locks = ["gate", "session"].map { service.paths.bottles.appendingPathComponent(".\(bottle.id).\($0).lock") }
        try fakeWine(service.paths.wineserver(for: bottle), calls: calls, probeLocks: locks)
        let held = Recorded()
        service.engineStep = { [unowned service] reached in
            guard reached == step else { return }
            held.append("wineserver " + ((try? String(contentsOf: calls, encoding: .utf8)) ?? "").split(separator: "\n").joined(separator: ", "))
            for kind in [WineService.BottleLockKind.gate, .session] {
                do {
                    let lock = try service.tryLock(kind, of: bottle, exclusive: false)
                    held.append("\(kind.rawValue) \(lock == nil ? "held" : "free")")
                    lock?.release()
                } catch { held.append("\(kind.rawValue) \(error)") }
            }
        }
        return held
    }

    /// A restore holds the bottle's gate and session while it swaps the snapshot in (or, the prefix gone, moves it in),
    /// so no managed start can start Wine under it, and asks the bottle's server to stop before it checks, holding
    /// both, that none runs.
    @Test(arguments: [true, false]) func aRestoreHoldsTheLocksThroughTheSwapAndStopsBeforeItProbes(prefixExists: Bool) async throws {
        let (root, service) = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (bottle, bottlePaths, snapshot, sentinel) = try await restorableBottle(service)
        if !prefixExists { try FileManager.default.removeItem(at: bottlePaths.prefix) }
        let restoredFile = bottlePaths.prefix.appendingPathComponent("only-in-snapshot.txt")
        try Data("snapshot".utf8).write(to: service.paths.snapshots(of: bottle).appendingPathComponent(snapshot.id).appendingPathComponent("prefix/only-in-snapshot.txt"))
        let held = try watchRestore(service, of: bottle, at: "snapshot:swap")
        try await service.restoreSnapshot(snapshot, of: bottle)
        #expect(held.values == ["wineserver -k held free, -k0 held held", "gate held", "session held"])
        #expect(contents(sentinel) == nil)
        #expect(contents(restoredFile) == "snapshot")
        #expect(service.paths.bottle(bottle).ready)
    }

    /// A save restore holds the bottle's gate and session while it copies the backup's files back, and asks the
    /// bottle's server to stop before it checks, holding both, that none runs.
    @Test func aSaveRestoreHoldsTheLocksThroughTheCopyAndStopsBeforeItProbes() async throws {
        let (root, service) = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (bottle, backup, save) = try await backedUpBottle(service)
        let held = try watchRestore(service, of: bottle, at: "saves:copy")
        try await service.restoreSaves(backup, to: bottle)
        #expect(held.values == ["wineserver -k held free, -k0 held held", "gate held", "session held"])
        #expect(contents(save) == "backed up")
    }

    /// A restorable bottle (without its prefix, when `prefixExists` is false) whose record gained a game after its
    /// snapshot, and whose snapshot holds a file the prefix does not: which prefix and which record a restore
    /// left show apart.
    func crashableRestore(_ service: WineService, prefixExists: Bool) async throws -> (Bottle, BottlePaths) {
        let (restorable, bottlePaths, snapshot, _) = try await restorableBottle(service)
        var bottle = restorable
        try Data("snapshot".utf8).write(to: service.paths.snapshots(of: bottle).appendingPathComponent(snapshot.id).appendingPathComponent("prefix/only-in-snapshot.txt"))
        bottle.games.append(Game(id: "after", name: "Added after the snapshot", executable: "after.exe"))
        try service.save(bottle)
        if !prefixExists { try FileManager.default.removeItem(at: bottlePaths.prefix) }
        return (bottle, bottlePaths)
    }

    /// Run in an exit test's own process: a restore of the bottle's "Earlier" snapshot or (`recovering`) the next
    /// holder of the bottle's gate (a start's engine check when the bottle has a prefix, else the app's start),
    /// stopped like a crash at its `n`th step with exit code `code`.
    static func runInterruptedRestore(root: URL, recovering: Bool, at n: Int, code: Int32) async throws {
        let service = WineService(paths: PortnautPaths(root: root), metalShim: nil)
        let stop = StepStop(at: n, code: code)
        service.engineStep = { stop.reach($0) }
        let bottle = try service.bottle(EngineProfileTests().gtaBottle().id)
        if recovering {
            try await recoverAfterRestore(service, bottle)
        } else {
            let snapshot = try #require(service.snapshots(of: bottle).first { $0.label == "Earlier" })
            try await service.restoreSnapshot(snapshot, of: bottle)
        }
    }
    static func recoverAfterRestore(_ service: WineService, _ bottle: Bottle) async throws {
        if service.paths.bottle(bottle).ready { try await service.requireEngine(of: bottle).release() } else { try service.recoverRestores() }
    }

    /// A snapshot restore stopped like a crash at any of its steps (writing the pending record, the swap, saving
    /// the record, removing the pending record and the replaced prefix, applying the engine), and the gate holder
    /// that recovers it stopped once more at each of its own steps, ends, once the app's start and a start's
    /// engine check have recovered it, with the bottle's prefix and record from the same side: the old prefix
    /// with the old record (or, without a prefix, none) when it stopped before the swap, the snapshot's prefix
    /// with the restored record after it; no pending record and nothing at the clone's place.
    @Test(arguments: [true, false], [false, true])
    func aRestoreCrashedAtAnyStepLeavesThePrefixAndRecordTogether(prefixExists: Bool, crashingRecovery: Bool) async throws {
        let fm = FileManager.default
        let (dryRoot, dryService) = try scratchRoot()
        defer { try? fm.removeItem(at: dryRoot) }
        let (dryBottle, _) = try await crashableRestore(dryService, prefixExists: prefixExists)
        let recorded = Recorded()
        dryService.engineStep = { if !$0.hasPrefix("sync:") { recorded.append($0) } }
        try await dryService.restoreSnapshot(try #require(dryService.snapshots(of: dryBottle).first { $0.label == "Earlier" }), of: dryBottle)
        let steps = recorded.values
        #expect(steps == ["snapshot:pending", "snapshot:swap", "snapshot:save", "snapshot:clear"] + (prefixExists ? ["snapshot:unstage"] : []) + ["snapshot:engine"])
        // `snapshot:swap` comes before the swap, `snapshot:save` after it.
        let swapped = try #require(steps.firstIndex(of: "snapshot:save"))
        for n in 1...steps.count {
            let (root, service) = try scratchRoot()
            defer { try? fm.removeItem(at: root) }
            let (bottle, _) = try await crashableRestore(service, prefixExists: prefixExists)
            await #expect(processExitsWith: .exitCode(42), "stopped at \(steps[n - 1])") { [root = root as URL, n = n as Int] in
                try await EngineProfileTests.runInterruptedRestore(root: root, recovering: false, at: n, code: 42)
            }
            // Each run of the recovering holder gets a copy of what the crash left, stopped at its own mth step;
            // the crashed root itself is recovered without a second stop.
            var ends = [(root, "stopped at \(steps[n - 1])")]
            var clones: [URL] = []
            defer { for clone in clones { try? fm.removeItem(at: clone) } }
            if crashingRecovery {
                let dry = try cloneRoot(root)
                clones.append(dry)
                let drySteps = Recorded()
                let dryRecovery = WineService(paths: PortnautPaths(root: dry), metalShim: nil)
                dryRecovery.engineStep = { if !$0.hasPrefix("sync:") { drySteps.append($0) } }
                try await Self.recoverAfterRestore(dryRecovery, bottle)
                let recoverySteps = drySteps.values
                #expect(!recoverySteps.isEmpty, "stopped at \(steps[n - 1]): a recovery with no step to stop at")
                for m in recoverySteps.indices.map({ $0 + 1 }) {
                    let copy = try cloneRoot(root)
                    clones.append(copy)
                    let context = "stopped at \(steps[n - 1]), recovery stopped at \(recoverySteps[m - 1])"
                    await #expect(processExitsWith: .exitCode(43), "\(context)") { [copy = copy as URL, m = m as Int] in
                        try await EngineProfileTests.runInterruptedRestore(root: copy, recovering: true, at: m, code: 43)
                    }
                    ends.append((copy, context))
                }
            }
            for (end, context) in ends {
                let fresh = WineService(paths: PortnautPaths(root: end), metalShim: nil)
                // The app's start alone recovers it; a start's engine check after it changes neither side.
                try fresh.recoverRestores()
                try expectRestoreEnded(fresh, bottle, snapshotSide: n - 1 >= swapped, prefixExists: prefixExists, "\(context), after the app's start")
                try await Self.recoverAfterRestore(fresh, bottle)
                try expectRestoreEnded(fresh, bottle, snapshotSide: n - 1 >= swapped, prefixExists: prefixExists, "\(context), after a start")
            }
        }
    }

    /// The bottle's prefix and record are both the snapshot's (`snapshotSide`) or both the old ones, with no pending
    /// record and nothing at the clone's place.
    func expectRestoreEnded(_ service: WineService, _ bottle: Bottle, snapshotSide: Bool, prefixExists: Bool, _ context: String) throws {
        let fm = FileManager.default
        let record = try service.bottle(bottle.id)
        let bottlePaths = service.paths.bottle(bottle)
        if snapshotSide {
            #expect(contents(bottlePaths.prefix.appendingPathComponent("only-in-snapshot.txt")) == "snapshot", "\(context)")
            #expect(contents(bottlePaths.drive.appendingPathComponent("after-snapshot.txt")) == nil, "\(context)")
            #expect(!record.games.contains { $0.id == "after" }, "\(context): the restored record")
        } else {
            #expect(fm.fileExists(atPath: bottlePaths.prefix.path) == prefixExists, "\(context)")
            if prefixExists {
                #expect(contents(bottlePaths.drive.appendingPathComponent("after-snapshot.txt")) == "kept", "\(context)")
                #expect(contents(bottlePaths.prefix.appendingPathComponent("only-in-snapshot.txt")) == nil, "\(context)")
            }
            #expect(record.games.contains { $0.id == "after" }, "\(context): the old record")
        }
        #expect(record.name == bottle.name, "\(context)")
        #expect((try? fm.attributesOfItem(atPath: bottlePaths.drive.appendingPathComponent(WineService.restorePending).path)) == nil, "\(context)")
        #expect((try? fm.attributesOfItem(atPath: service.stagedRestore(of: bottle).path)) == nil, "\(context)")
    }

    /// A recovery of a restore stopped right after its swap makes the swap durable before it saves the record,
    /// as the stopped restore may not have.
    @Test func aRecoveryMakesTheSwapDurableBeforeItSavesTheRecord() async throws {
        let (root, service) = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (bottle, _) = try await crashableRestore(service, prefixExists: true)
        // The restore's third step, `snapshot:save`, comes once its swap is done.
        await #expect(processExitsWith: .exitCode(42)) { [root = root as URL] in
            try await EngineProfileTests.runInterruptedRestore(root: root, recovering: false, at: 3, code: 42)
        }
        let recorded = Recorded()
        service.engineStep = { recorded.append($0) }
        try service.recoverRestores()
        let steps = recorded.values
        let save = try #require(steps.firstIndex(of: "snapshot:save"), "\(steps)")
        let synced = try #require(steps.firstIndex(of: "sync:" + service.paths.bottles.path), "\(steps)")
        #expect(synced < save)
        try expectRestoreEnded(service, bottle, snapshotSide: true, prefixExists: true, "recovered")
    }

    /// The app's start recovers every bottle it can: one whose pending record cannot be read stops only its own
    /// recovery, reported once the others are done.
    @Test func theAppsStartRecoversTheOtherBottlesPastOneItCannot() throws {
        let (root, service) = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var broken = gtaBottle(), other = gtaBottle()
        broken.id = "a-broken"; other.id = "b-other"
        try service.paths.saveLibrary(Library(bottles: [broken, other]))
        let pending = service.paths.bottle(broken).drive.appendingPathComponent(WineService.restorePending)
        try FileManager.default.createDirectory(at: pending.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{".utf8).write(to: pending)
        try FileManager.default.createDirectory(at: service.stagedRestore(of: other), withIntermediateDirectories: true)
        let failed = #expect(throws: PortnautError.self) { try service.recoverRestores() }
        #expect(failed?.message.contains(pending.path) == true)
        #expect((try? FileManager.default.attributesOfItem(atPath: service.stagedRestore(of: other).path)) == nil)
        #expect(FileManager.default.fileExists(atPath: pending.path))
    }

    /// A library save removes the temporary file a crashed one left beside library.json.
    @Test func aLibrarySaveRemovesWhatACrashedOneLeft() throws {
        let (root, service) = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let left = root.appendingPathComponent(".library.json" + Durable.temporaryMark + UUID().uuidString)
        try Data("{".utf8).write(to: left)
        let bottle = gtaBottle()
        try service.save(bottle)
        #expect(!FileManager.default.fileExists(atPath: left.path))
        #expect(try service.bottle(bottle.id) == bottle)
    }

    /// An APFS clone of a scratch root beside it, for a run that must not change the original.
    func cloneRoot(_ root: URL) throws -> URL {
        let copy = root.deletingLastPathComponent().appendingPathComponent("portnaut-engine-" + UUID().uuidString)
        guard clonefile(root.path, copy.path, 0) == 0 else { throw PortnautError("clonefile: \(String(cString: strerror(errno)))") }
        return copy
    }

    /// The pending record and the swap are durable before the record that relies on them is saved, and the
    /// saved record is durable before the pending one goes. (Power loss is not reproducible; this checks the order.)
    @Test func aRestoreIsDurableBeforeTheStepsThatRelyOnIt() async throws {
        let (root, service) = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (bottle, _) = try await crashableRestore(service, prefixExists: true)
        let recorded = Recorded()
        service.engineStep = { recorded.append($0) }
        try await service.restoreSnapshot(try #require(service.snapshots(of: bottle).first { $0.label == "Earlier" }), of: bottle)
        let steps = recorded.values
        let staged = service.stagedRestore(of: bottle)
        let pendingFolder = BottlePaths(prefix: staged).drive.appendingPathComponent(WineService.restorePending).deletingLastPathComponent()
        func index(_ step: String) throws -> Int { try #require(steps.firstIndex(of: step), "\(step) in \(steps)") }
        let swap = try index("snapshot:swap"), save = try index("snapshot:save"), clear = try index("snapshot:clear")
        #expect(steps[..<swap].contains { $0.hasPrefix("sync:" + pendingFolder.path + "/." + URL(fileURLWithPath: WineService.restorePending).lastPathComponent + Durable.temporaryMark) })
        for folder in [pendingFolder, BottlePaths(prefix: staged).drive, staged] { #expect(try index("sync:" + folder.path) < swap, "\(folder.path)") }
        #expect(try index("sync:" + service.paths.bottles.path) > swap && index("sync:" + service.paths.bottles.path) < save)
        // The saved record (library.json's data, then its folder) is durable before the pending record goes.
        let library = service.paths.library
        #expect(steps[save..<clear].contains { $0.hasPrefix("sync:" + library.deletingLastPathComponent().path + "/." + library.lastPathComponent + Durable.temporaryMark) })
        #expect(try index("sync:" + library.deletingLastPathComponent().path) > save && index("sync:" + library.deletingLastPathComponent().path) < clear)
        #expect(try index("sync:" + service.paths.bottle(bottle).drive.appendingPathComponent("Portnaut").path) > clear)
    }

    /// A save backup of a restorable bottle, and its save changed since, which a restore that did not happen
    /// leaves changed.
    func backedUpBottle(_ service: WineService) async throws -> (Bottle, SaveBackup, URL) {
        let (bottle, bottlePaths, _, _) = try await restorableBottle(service)
        let save = bottlePaths.drive.appendingPathComponent("users/player/Saved Games/Game/slot1.sav")
        try FileManager.default.createDirectory(at: save.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("backed up".utf8).write(to: save)
        let backup = try await service.backUpSaves(of: bottle)
        try Data("changed".utf8).write(to: save)
        return (bottle, backup, save)
    }

    /// A save restore refuses while a managed start holds the session, instead of copying over files its program
    /// is about to use.
    @Test func aSaveRestoreRefusesWhileAStartHoldsTheSession() async throws {
        let (root, service) = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (bottle, backup, save) = try await backedUpBottle(service)
        let session = try await service.requireEngine(of: bottle)
        defer { session.release() }
        let refused = await #expect(throws: PortnautError.self) { try await service.restoreSaves(backup, to: bottle) }
        #expect(refused?.message.hasPrefix("Quit the Windows programs") == true)
        #expect(contents(save) == "changed")
        #expect(service.snapshots(of: bottle).count == 1)
    }

    /// A Wine server still running after the stop makes a save restore refuse before any file is copied.
    @Test func aSaveRestoreRefusesWhileAWineServerRuns() async throws {
        let (root, service) = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (bottle, backup, save) = try await backedUpBottle(service)
        try fakeWine(service.paths.wineserver(for: bottle), probeStatus: 0)
        let refused = await #expect(throws: PortnautError.self) { try await service.restoreSaves(backup, to: bottle) }
        #expect(refused?.message.hasPrefix("Quit the Windows programs") == true)
        #expect(contents(save) == "changed")
        #expect(service.snapshots(of: bottle).count == 1)
    }

    /// A save restore cancelled while it waits for the gate copies nothing once it gets the gate.
    @Test func aSaveRestoreCancelledWhileWaitingForTheGateChangesNothing() async throws {
        let (root, service) = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (bottle, backup, save) = try await backedUpBottle(service)
        let gate = try await service.waitForLock(.gate, of: bottle, exclusive: true)
        let first = FirstEvent()
        service.lockContended = { kind in first.signal("contended \(kind.rawValue)") }
        let restore = Task {
            defer { first.signal("restore ended") }
            try await service.restoreSaves(backup, to: bottle)
        }
        #expect(await first.value == "contended gate")
        restore.cancel()
        gate.release()
        await #expect(throws: CancellationError.self) { try await restore.value }
        #expect(contents(save) == "changed")
        #expect(service.snapshots(of: bottle).count == 1)
    }

    /// A save restore of an idle bottle (its server probed: none runs) keeps the current saves in an automatic
    /// snapshot, then copies the backup's files back.
    @Test func aSaveRestoreOfAnIdleBottleCopiesTheBackup() async throws {
        let (root, service) = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (bottle, backup, save) = try await backedUpBottle(service)
        try await service.restoreSaves(backup, to: bottle)
        #expect(contents(save) == "backed up")
        let automatic = try #require(service.snapshots(of: bottle).first { $0.automatic })
        let kept = service.paths.snapshots(of: bottle).appendingPathComponent(automatic.id).appendingPathComponent("prefix/drive_c/users/player/Saved Games/Game/slot1.sav")
        #expect(contents(kept) == "changed")
    }

    @Test func aProfileBottleHasNoBestSetup() {
        let game = Game(id: "gta5", name: "GTA V Enhanced", executable: EngineProfile.gameFolder + "/GTA5_Enhanced.exe")
        let service = WineService(paths: PortnautPaths(root: URL(fileURLWithPath: "/tmp/portnaut-root")), metalShim: nil)
        #expect(throws: PortnautError.self) { try service.startSetupTrial(for: game, in: gtaBottle()) }
    }
}
