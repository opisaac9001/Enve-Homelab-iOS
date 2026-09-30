import XCTest

@MainActor
final class PreviewFlowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }

    private func row(_ prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    private func element(containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// Menus can miss a tap while a sheet or navigation transition settles.
    private func choose(_ item: String, fromMenu menu: XCUIElement) {
        let option = app.buttons[item]
        for _ in 0..<3 where !option.exists {
            menu.tap()
            _ = option.waitForExistence(timeout: 3)
        }
        option.tap()
    }

    private func back() {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    private func tab(_ title: String) {
        let button = app.buttons[title].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
    }

    func testPreviewCommandCentreFlows() {
        app.launchArguments = ["-previewMode", "-isolatedStorage"]
        app.launch()

        XCTAssertTrue(app.staticTexts["atlas"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Needs attention"].waitForExistence(timeout: 5))
        snapshot("01-overview")

        tab("Storage")
        XCTAssertTrue(app.staticTexts["Array devices"].waitForExistence(timeout: 5))
        snapshot("02-storage")
        app.buttons["Disk5"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Errors"].waitForExistence(timeout: 5))
        snapshot("03-disk-detail")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        tab("Docker")
        XCTAssertTrue(app.staticTexts["jellyfin"].waitForExistence(timeout: 5))
        snapshot("04-docker")
        row("jellyfin").tap()
        XCTAssertTrue(app.staticTexts["Volumes"].waitForExistence(timeout: 5))
        snapshot("05-container-detail")

        app.buttons["Stop"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Stop Container"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Preview mode: only sample data changes."].exists)
        snapshot("06-stop-confirmation")
        app.buttons.matching(identifier: "Stop Container").element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["Start"].waitForExistence(timeout: 5))
        snapshot("07-container-stopped")

        app.buttons["Logs"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'health check passed'")).firstMatch.waitForExistence(timeout: 5))
        snapshot("08-logs")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        tab("VMs")
        XCTAssertTrue(app.staticTexts["Windows 11 Workstation"].waitForExistence(timeout: 5))
        snapshot("09-vms")
        row("Windows 11 Workstation").tap()
        app.buttons["Force Stop"].firstMatch.tap()
        let confirm = app.buttons.matching(identifier: "Force Stop VM").element(boundBy: 0)
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertFalse(confirm.isEnabled, "Destructive action must require typing the VM name")
        let field = app.textFields["Confirmation name"]
        for _ in 0..<3 where (field.value(forKey: "hasKeyboardFocus") as? Bool) != true {
            field.tap()
            sleep(1)
        }
        field.typeText("Windows 11 Workstation")
        XCTAssertTrue(confirm.isEnabled)
        snapshot("10-force-stop-typed")
        confirm.tap()
        XCTAssertTrue(app.buttons["Start"].waitForExistence(timeout: 5))
        snapshot("11-vm-stopped")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        tab("Alerts")
        XCTAssertTrue(app.staticTexts["disk5 has read errors"].waitForExistence(timeout: 5))
        snapshot("12-alerts")
        app.buttons["Archive All"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Every unread notification on the server moves'")).firstMatch.waitForExistence(timeout: 5))
        app.buttons.matching(identifier: "Archive All").element(boundBy: 1).tap()
        XCTAssertTrue(app.staticTexts["All caught up"].waitForExistence(timeout: 5))
        snapshot("13-alerts-archived")
    }

    func testAddServerValidationAndUnreachableTest() {
        app.launchArguments = ["-isolatedStorage"]
        app.launch()
        let add = app.buttons["Add Unraid Server"]
        guard add.waitForExistence(timeout: 5) else { return }
        add.tap()

        XCTAssertTrue(app.staticTexts["Enter a name."].waitForExistence(timeout: 5))
        let name = app.textFields["Name"]
        name.tap()
        name.typeText("Test Tower")
        let local = app.textFields["Local network address"]
        local.tap()
        local.typeText("http://127.0.0.1:9")
        let key = app.secureTextFields.firstMatch
        key.tap()
        key.typeText("not-a-real-key")
        XCTAssertTrue(app.staticTexts["http://127.0.0.1:9/graphql"].waitForExistence(timeout: 5))
        snapshot("14-editor")

        app.buttons["Test Connection"].tap()
        XCTAssertTrue(app.staticTexts["The server couldn't be reached."].waitForExistence(timeout: 30))
        snapshot("15-editor-unreachable")
        app.buttons["Cancel"].tap()
    }

    func testPreviewLiveStorageArrayAndUpdates() {
        app.launchArguments = ["-previewMode", "-isolatedStorage"]
        app.launch()

        XCTAssertTrue(element(containing: "Live updates").waitForExistence(timeout: 10), "Metrics should stream from the subscription")
        XCTAssertTrue(element(containing: "Rack UPS").waitForExistence(timeout: 10))
        app.swipeUp()
        snapshot("20-overview-live-ups")

        tab("Storage")
        XCTAssertTrue(app.buttons["Array Operation…"].waitForExistence(timeout: 10))
        app.buttons["Array Operation…"].tap()
        XCTAssertTrue(element(containing: "7 running containers will be stopped.").waitForExistence(timeout: 10))
        let stop = app.buttons["Stop Array"]
        XCTAssertTrue(stop.exists)
        XCTAssertFalse(stop.isEnabled, "Stopping must require the typed server name")
        let field = app.textFields["Type the server name to confirm"]
        field.tap()
        field.typeText("atlas")
        XCTAssertTrue(stop.isEnabled)
        snapshot("21-array-stop-review")
        stop.tap()
        XCTAssertTrue(element(containing: "The array is now stopped.").waitForExistence(timeout: 10))
        snapshot("22-array-stopped")
        app.buttons["Done"].tap()
        XCTAssertTrue(element(containing: "Stopped").waitForExistence(timeout: 10))

        app.buttons["Array Operation…"].tap()
        let start = app.buttons["Start Array"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        app.textFields["Type the server name to confirm"].tap()
        app.textFields["Type the server name to confirm"].typeText("atlas")
        start.tap()
        XCTAssertTrue(element(containing: "The array is now started.").waitForExistence(timeout: 10))
        app.buttons["Done"].tap()

        app.buttons["Shares"].firstMatch.tap()
        XCTAssertTrue(element(containing: "Films, series and music").waitForExistence(timeout: 10))
        snapshot("23-shares")
        back()

        row("Disk1").tap()
        XCTAssertTrue(element(containing: "Drive health").waitForExistence(timeout: 5))
        app.swipeUp()
        XCTAssertTrue(element(containing: "SMART").waitForExistence(timeout: 10))
        snapshot("24-disk-health")
        back()

        tab("Docker")
        row("nextcloud").tap()
        XCTAssertTrue(element(containing: "A newer image is available.").waitForExistence(timeout: 10))
        snapshot("25-container-update-available")
        app.buttons["Update Container…"].tap()
        let confirm = app.buttons.matching(identifier: "Update Container").element(boundBy: 0)
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(element(containing: "Up to date as of the server's last check.").waitForExistence(timeout: 15))
        snapshot("26-container-updated")
    }

    func testServiceCheckAndSSHHostManagement() {
        app.launchArguments = ["-isolatedStorage"]
        app.launch()

        XCTAssertTrue(app.buttons["Service Check"].waitForExistence(timeout: 10))
        app.buttons["Service Check"].tap()
        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Closed port")
        let url = app.textFields["URL"]
        url.tap()
        url.typeText("http://127.0.0.1:9/health")
        snapshot("30-service-editor")
        app.buttons["Save"].tap()

        XCTAssertTrue(row("Closed port").waitForExistence(timeout: 10))
        XCTAssertTrue(element(containing: "The server couldn't be reached.").waitForExistence(timeout: 20))
        snapshot("31-home-services")
        row("Closed port").tap()
        XCTAssertTrue(element(containing: "Check Now").waitForExistence(timeout: 5))
        snapshot("32-service-detail-down")
        back()

        choose("SSH Host", fromMenu: app.buttons["Add"])
        let hostName = app.textFields["Name"]
        XCTAssertTrue(hostName.waitForExistence(timeout: 5))
        hostName.tap()
        hostName.typeText("Closed SSH")
        app.textFields["Host name or IP address"].tap()
        app.textFields["Host name or IP address"].typeText("127.0.0.1")
        app.textFields["ssh-port"].tap()
        app.textFields["ssh-port"].typeText("9")
        app.secureTextFields.firstMatch.tap()
        app.secureTextFields.firstMatch.typeText("not-a-password")
        app.swipeUp()
        app.buttons["Add Command"].tap()
        let commandName = app.textFields["Command name"]
        XCTAssertTrue(commandName.waitForExistence(timeout: 5))
        commandName.tap()
        commandName.typeText("Clean cache")
        app.textFields["Command"].tap()
        app.textFields["Command"].typeText("rm -rf /mnt/cache/tmp")
        XCTAssertTrue(element(containing: "Deletes files recursively").waitForExistence(timeout: 5))
        snapshot("33-risky-saved-command")
        app.buttons["Done"].tap()
        app.buttons["Save"].tap()

        XCTAssertTrue(row("Closed SSH").waitForExistence(timeout: 10))
        app.swipeUp()
        app.buttons["SSH Keys"].tap()
        XCTAssertTrue(app.buttons["Add Key"].waitForExistence(timeout: 5))
        choose("Generate Ed25519 Key", fromMenu: app.buttons["Add Key"])
        let keyName = app.textFields["Name"]
        XCTAssertTrue(keyName.waitForExistence(timeout: 5))
        keyName.tap()
        keyName.typeText("Phone")
        app.buttons["Save"].tap()
        XCTAssertTrue(element(containing: "SHA256:").waitForExistence(timeout: 5))
        snapshot("34-ssh-keys")
        back()

        row("Closed SSH").tap()
        XCTAssertTrue(element(containing: "Couldn't connect").waitForExistence(timeout: 20))
        snapshot("35-terminal-refused")
    }

    func testRealTerminalAgainstFixtureServer() throws {
        guard let directory = ProcessInfo.processInfo.environment["INTEGRATION_DIR"] else {
            throw XCTSkip("Run Scripts/run-integration-tests.sh to provide a fixture sshd")
        }
        let read = { (name: String) in
            try String(contentsOfFile: "\(directory)/\(name)", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let privateKey = try read("client_ed25519")
        let fingerprint = try read("host_fingerprint")

        app.launchArguments = ["-isolatedStorage"]
        app.launch()

        XCTAssertTrue(app.buttons["SSH Host"].waitForExistence(timeout: 10))
        app.buttons["SSH Host"].tap()
        app.textFields["Name"].tap()
        app.textFields["Name"].typeText("Fixture")
        app.textFields["Host name or IP address"].tap()
        app.textFields["Host name or IP address"].typeText("127.0.0.1")
        app.textFields["ssh-port"].tap()
        app.textFields["ssh-port"].typeText(try read("ssh_port"))
        app.textFields["Username"].tap()
        app.textFields["Username"].typeText(try read("ssh_user"))
        app.secureTextFields.firstMatch.tap()
        app.secureTextFields.firstMatch.typeText("unused")
        app.buttons["Save"].tap()

        let keys = app.buttons["SSH Keys"]
        XCTAssertTrue(keys.waitForExistence(timeout: 5))
        let addKey = app.buttons["Add Key"]
        for _ in 0..<3 where !addKey.exists {
            keys.tap()
            _ = addKey.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(addKey.exists)
        choose("Import Private Key", fromMenu: addKey)
        app.textFields["Name"].tap()
        app.textFields["Name"].typeText("Fixture key")
        let keyField = app.textFields["-----BEGIN OPENSSH PRIVATE KEY-----"]
        keyField.tap()
        keyField.typeText(privateKey.replacingOccurrences(of: "\n", with: " "))
        app.buttons["Save"].tap()
        XCTAssertTrue(element(containing: "Fixture key").waitForExistence(timeout: 5))
        snapshot("40-imported-key")
        back()

        row("Fixture").swipeLeft()
        app.buttons["Edit"].tap()
        app.buttons["Key"].tap()
        app.buttons["Key, Choose…"].tap()
        let option = app.buttons["Fixture key"].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.tap()
        app.buttons["Save"].tap()

        let review = element(containing: "New host key")
        row("Fixture").tap()
        XCTAssertTrue(review.waitForExistence(timeout: 15))
        XCTAssertTrue(element(containing: fingerprint).exists, "Review must show the fingerprint the server presented")
        let trust = app.buttons["Trust and Connect"]
        XCTAssertFalse(trust.isEnabled, "Trusting must require confirming the fingerprint")
        snapshot("41-host-key-review")
        app.switches.firstMatch.tap()
        trust.tap()

        XCTAssertTrue(element(containing: "Connected ·").waitForExistence(timeout: 15))
        app.typeText("echo enve-$((20+22))\n")
        sleep(2)
        snapshot("42-terminal-connected")
        back()

        row("Fixture").tap()
        XCTAssertTrue(element(containing: "Connected ·").waitForExistence(timeout: 15), "A trusted key should connect without review")
    }

    /// Scrolls the home list from the top until the element can be tapped.
    private func reveal(_ element: XCUIElement) {
        for _ in 0..<4 { app.swipeDown() }
        for _ in 0..<25 where !(element.exists && element.isHittable) {
            app.swipeUp()
        }
    }

    func testSampleIntegrationsSearchAlertsAndViewOnlyProfile() {
        app.launchArguments = ["-isolatedStorage", "-sampleIntegrations"]
        app.launch()

        XCTAssertTrue(row("Sample Proxmox VE").waitForExistence(timeout: 10))
        snapshot("50-home-integrations")
        let pihole = row("Sample Pi-hole")
        reveal(pihole)
        pihole.tap()
        let pause = app.buttons["Pause Blocking…"]
        XCTAssertTrue(pause.waitForExistence(timeout: 10))
        snapshot("51-pihole")
        pause.tap()
        let confirm = app.buttons.matching(identifier: "Pause Blocking").element(boundBy: 0)
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(element(containing: "Ads and trackers will load").exists)
        confirm.tap()
        XCTAssertTrue(element(containing: "Blocking is paused").waitForExistence(timeout: 10))
        back()

        let homeAssistant = row("Sample Home Assistant")
        reveal(homeAssistant)
        homeAssistant.tap()
        XCTAssertTrue(element(containing: "Kitchen lights").waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Open…"].exists, "Covers need confirmation")
        XCTAssertFalse(element(containing: "Front door").exists, "Locks are hidden while showing controllable entities only")
        snapshot("52-home-assistant")
        back()

        let unifi = row("Sample UniFi Network")
        reveal(unifi)
        unifi.tap()
        XCTAssertTrue(element(containing: "Garage AP").waitForExistence(timeout: 10))
        snapshot("53-unifi")
        back()

        app.swipeDown()
        app.swipeDown()
        app.buttons["Search"].firstMatch.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("tail")
        XCTAssertTrue(row("Sample Tailscale").waitForExistence(timeout: 5))
        snapshot("54-search")
        // The active search field owns the first navigation-bar button (Cancel or Close) until dismissed.
        for _ in 0..<3 where !app.buttons["Settings"].firstMatch.exists {
            back()
            _ = app.buttons["Settings"].firstMatch.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(app.buttons["Settings"].firstMatch.exists)

        app.buttons["Settings"].firstMatch.tap()
        let profile = element(containing: "Owner · Owner")
        XCTAssertTrue(profile.waitForExistence(timeout: 5))
        profile.tap()
        app.buttons["Add Profile"].tap()
        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Guest")
        app.buttons["Save"].tap()
        let guest = row("Guest")
        XCTAssertTrue(guest.waitForExistence(timeout: 5))
        guest.tap()
        let switchToViewer = app.buttons["Switch to View Only"]
        XCTAssertTrue(switchToViewer.waitForExistence(timeout: 5), "Dropping to view-only explains what changes first")
        XCTAssertTrue(element(containing: "Anyone holding this device can switch back").exists)
        switchToViewer.tap()
        XCTAssertTrue(element(containing: "Guest, View only").waitForExistence(timeout: 5) || element(containing: "Active").exists)
        snapshot("55-profiles")
        back()
        back()

        XCTAssertFalse(app.buttons["Add"].exists, "View-only profiles can't add connections")
        reveal(pihole)
        pihole.tap()
        let resume = app.buttons["Turn Blocking On"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
        XCTAssertFalse(resume.isEnabled, "View-only profiles can't change servers")
        snapshot("56-view-only")
    }

    func testSetupGuideAndTrustHelp() {
        app.launchArguments = ["-isolatedStorage", "-sampleIntegrations"]
        app.launch()

        let add = app.buttons["Add"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        choose("Integration", fromMenu: add)
        let truenas = row("TrueNAS")
        XCTAssertTrue(truenas.waitForExistence(timeout: 5))
        truenas.tap()
        let guide = row("How to connect TrueNAS")
        XCTAssertTrue(guide.waitForExistence(timeout: 5))
        guide.tap()
        XCTAssertTrue(app.navigationBars["Connect TrueNAS"].waitForExistence(timeout: 5))
        XCTAssertTrue(element(containing: "Permissions").exists)
        snapshot("60-setup-guide")
        back()
        back()
        app.buttons["Cancel"].firstMatch.tap()

        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        let trust = row("Trust & Security")
        XCTAssertTrue(trust.waitForExistence(timeout: 5))
        trust.tap()
        XCTAssertTrue(element(containing: "Plain HTTP").waitForExistence(timeout: 5))
        XCTAssertTrue(element(containing: "SHA-256 fingerprint").exists)
        snapshot("61-trust-help")
    }

    func testSampleServiceDashboardsConfirmActions() {
        app.launchArguments = ["-isolatedStorage", "-sampleIntegrations"]
        app.launch()

        XCTAssertTrue(row("Sample Proxmox VE").waitForExistence(timeout: 10))
        let tautulli = row("Sample Tautulli")
        reveal(tautulli)
        tautulli.tap()
        XCTAssertTrue(element(containing: "Now Playing").waitForExistence(timeout: 10))
        let actions = app.buttons["Actions for Open Source Chronicles - Merge Conflict"]
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        actions.tap()
        let stop = app.buttons["Stop Stream…"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        stop.tap()
        XCTAssertTrue(element(containing: "Plex Pass").waitForExistence(timeout: 5), "The confirmation names the consequence")
        XCTAssertTrue(element(containing: "Alex — Open Source Chronicles").exists, "The confirmation names the exact target")
        snapshot("62-tautulli-stop-confirmation")
        app.buttons["Cancel"].firstMatch.tap()
        back()

        let glances = row("Sample Glances")
        reveal(glances)
        glances.tap()
        XCTAssertTrue(element(containing: "File Systems").waitForExistence(timeout: 10))
        XCTAssertTrue(element(containing: "/mnt/backup").exists)
        snapshot("63-glances")
        back()

        let gluetun = row("Sample Gluetun")
        reveal(gluetun)
        gluetun.tap()
        let stopVPN = app.buttons["Stop VPN…"]
        XCTAssertTrue(stopVPN.waitForExistence(timeout: 10))
        stopVPN.tap()
        XCTAssertTrue(element(containing: "loses internet access").waitForExistence(timeout: 5), "Stopping the VPN explains the kill switch")
        snapshot("64-gluetun-stop-confirmation")
        app.buttons["Cancel"].firstMatch.tap()
    }

    func testSampleMediaServerManagement() {
        app.launchArguments = ["-isolatedStorage", "-sampleIntegrations"]
        app.launch()

        XCTAssertTrue(row("Sample Proxmox VE").waitForExistence(timeout: 10))
        let jellyfin = row("Sample Jellyfin")
        reveal(jellyfin)
        jellyfin.tap()
        XCTAssertTrue(element(containing: "A restart is pending").waitForExistence(timeout: 10))
        XCTAssertTrue(element(containing: "English · EAC3 5.1").exists, "The playing audio track is shown")

        let more = app.buttons["More controls for Our Summer Trip"]
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap()
        XCTAssertTrue(app.buttons["Send Message…"].waitForExistence(timeout: 5), "The client advertises DisplayMessage")
        XCTAssertTrue(app.buttons["Subtitles"].exists)
        app.buttons["Send Message…"].tap()
        XCTAssertTrue(app.textFields["Message"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].firstMatch.tap()

        let restart = app.buttons["Restart Server…"]
        XCTAssertTrue(restart.waitForExistence(timeout: 5))
        restart.tap()
        XCTAssertTrue(element(containing: "Every stream stops").waitForExistence(timeout: 5), "Restarting explains the consequence")
        snapshot("65-jellyfin-restart-confirmation")
        app.buttons["Cancel"].firstMatch.tap()

        for _ in 0..<6 where !element(containing: "ffmpeg exited with code 1").exists { app.swipeUp() }
        XCTAssertTrue(element(containing: "ffmpeg exited with code 1").exists, "Failed scheduled tasks show their error")
        snapshot("66-jellyfin-tasks")
    }

    func testUpcomingPinsLayoutAndErase() {
        app.launchArguments = ["-isolatedStorage", "-sampleIntegrations"]
        app.launch()

        XCTAssertTrue(row("Sample Proxmox VE").waitForExistence(timeout: 10))
        let pihole = row("Sample Pi-hole")
        reveal(pihole)
        pihole.press(forDuration: 1.2)
        let pin = app.buttons["Pin to Home"]
        XCTAssertTrue(pin.waitForExistence(timeout: 5))
        pin.tap()
        for _ in 0..<6 { app.swipeDown() }
        XCTAssertTrue(app.staticTexts["Pinned"].waitForExistence(timeout: 5), "Pinned items get their own home section")
        snapshot("71-pinned")

        let schedule = app.buttons["Schedule"].firstMatch
        reveal(schedule)
        schedule.tap()
        XCTAssertTrue(element(containing: "Sample Documentary").waitForExistence(timeout: 10))
        XCTAssertTrue(element(containing: "Tomorrow").exists)
        XCTAssertTrue(element(containing: "Live at the Library").exists, "Lidarr releases are included")
        XCTAssertFalse(element(containing: "Field Recordings").exists, "Unmonitored items are hidden by default")
        snapshot("70-upcoming")
        app.buttons["Missing"].firstMatch.tap()
        XCTAssertTrue(element(containing: "Harbour Lights").waitForExistence(timeout: 10))
        XCTAssertTrue(element(containing: "Missing in total").exists)
        app.buttons["In Queue"].firstMatch.tap()
        XCTAssertTrue(element(containing: "left").waitForExistence(timeout: 10), "Queue rows show time left")
        snapshot("70b-schedule-queue")
        back()

        app.buttons["Settings"].firstMatch.tap()
        let layout = row("Home & Tabs")
        XCTAssertTrue(layout.waitForExistence(timeout: 5))
        layout.tap()
        let pinnedToggle = app.switches["Pinned"].firstMatch
        XCTAssertTrue(pinnedToggle.waitForExistence(timeout: 5))
        XCTAssertTrue(element(containing: "Sample Pi-hole").exists, "Pins are listed for reordering")
        snapshot("72-home-layout")
        back()

        let privacy = row("Privacy & Data")
        XCTAssertTrue(privacy.waitForExistence(timeout: 5))
        privacy.tap()
        XCTAssertTrue(element(containing: "Unraid servers").waitForExistence(timeout: 5), "Stored data is listed with counts")
        XCTAssertTrue(element(containing: "marked for this device only").exists)
        let eraseEntry = app.buttons["Erase All Data…"]
        for _ in 0..<4 where !eraseEntry.isHittable { app.swipeUp() }
        eraseEntry.tap()
        let erase = app.buttons["Erase All Data"].firstMatch
        XCTAssertTrue(erase.waitForExistence(timeout: 5))
        XCTAssertFalse(erase.isEnabled, "Erasing needs the typed confirmation")
        let phrase = app.textFields.firstMatch
        phrase.tap()
        phrase.typeText("ERASE")
        XCTAssertTrue(erase.isEnabled)
        snapshot("73-erase-confirmation")
        erase.tap()

        XCTAssertTrue(row("Sample Proxmox VE").waitForExistence(timeout: 10), "The app starts over on home")
        for _ in 0..<6 { app.swipeDown() }
        XCTAssertFalse(app.staticTexts["Pinned"].exists, "Erasing removes the home layout too")
    }

    func testSampleRequestsStatisticsAndImports() {
        app.launchArguments = ["-isolatedStorage", "-sampleIntegrations"]
        app.launch()

        XCTAssertTrue(row("Sample Proxmox VE").waitForExistence(timeout: 10))
        let seerr = row("Sample Seerr")
        reveal(seerr)
        seerr.tap()
        XCTAssertTrue(element(containing: "Pending approval").waitForExistence(timeout: 10))
        let actions = app.buttons["Actions for Open Film Festival Highlights"]
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        snapshot("80-requests")
        actions.tap()
        app.buttons["Approve…"].tap()
        let routing = app.switches["Choose where it goes"].firstMatch
        XCTAssertTrue(routing.waitForExistence(timeout: 10), "Routing options load from the Radarr servers Seerr knows")
        XCTAssertTrue(element(containing: "searches your indexers and downloads it").exists, "Approval explains what happens next")
        routing.switches.firstMatch.tap()
        let approve = app.buttons["Approve and Send to Radarr"]
        XCTAssertTrue(approve.waitForExistence(timeout: 5))
        snapshot("81-approve-routing")
        approve.tap()
        XCTAssertTrue(element(containing: "sent it to Radarr").waitForExistence(timeout: 10))
        app.buttons["Issues"].firstMatch.tap()
        XCTAssertTrue(element(containing: "subtitles drift").waitForExistence(timeout: 10))
        back()

        let statistics = app.buttons["Statistics"].firstMatch
        reveal(statistics)
        statistics.tap()
        XCTAssertTrue(element(containing: "Plays per day").waitForExistence(timeout: 10))
        XCTAssertTrue(element(containing: "Most watched shows").exists)
        snapshot("82-statistics")
        back()

        for _ in 0..<6 { app.swipeDown() }
        let add = app.buttons["Add"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        choose("Import from Docker Host…", fromMenu: add)
        let host = app.textFields.firstMatch
        XCTAssertTrue(host.waitForExistence(timeout: 5))
        host.tap()
        host.typeText("192.168.1.20")
        XCTAssertTrue(element(containing: "--host 192.168.1.20 -o petty-homelab.json").exists, "The command uses the address typed")
        XCTAssertTrue(app.buttons["Save the Script…"].exists, "The script ships inside the app")
        snapshot("83-docker-import")
        app.buttons["Close"].firstMatch.tap()
    }

    func testLimitedViewOnlyProfileHidesOtherItems() {
        app.launchArguments = ["-isolatedStorage", "-sampleIntegrations"]
        app.launch()

        XCTAssertTrue(row("Sample Proxmox VE").waitForExistence(timeout: 10))
        app.buttons["Settings"].firstMatch.tap()
        let profile = element(containing: "Owner · Owner")
        XCTAssertTrue(profile.waitForExistence(timeout: 5))
        profile.tap()
        app.buttons["Add Profile"].tap()
        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Kids")
        let everything = app.switches["Every integration and check"].firstMatch
        XCTAssertTrue(everything.waitForExistence(timeout: 5))
        everything.switches.firstMatch.tap()
        XCTAssertTrue(element(containing: "Show all Infrastructure").waitForExistence(timeout: 5), "Each category can be shown or hidden at once")
        let pihole = app.switches.matching(NSPredicate(format: "label BEGINSWITH %@", "Sample Pi-hole")).firstMatch
        for _ in 0..<8 where !pihole.exists { app.swipeUp() }
        XCTAssertTrue(pihole.waitForExistence(timeout: 5), "Items are grouped by category")
        pihole.switches.firstMatch.tap()
        snapshot("90-limited-profile")
        app.buttons["Save"].tap()

        let kids = row("Kids")
        XCTAssertTrue(kids.waitForExistence(timeout: 5))
        XCTAssertTrue(element(containing: "View only · limited").exists)
        kids.tap()
        let switchToViewer = app.buttons["Switch to View Only"]
        XCTAssertTrue(switchToViewer.waitForExistence(timeout: 5))
        switchToViewer.tap()
        _ = element(containing: "Active").waitForExistence(timeout: 5)
        back()
        back()

        XCTAssertTrue(element(containing: "Viewing as Kids").waitForExistence(timeout: 10), "Home says which profile is in use")
        XCTAssertTrue(row("Sample Pi-hole").waitForExistence(timeout: 10), "Chosen items stay visible")
        XCTAssertFalse(row("Sample Proxmox VE").exists, "Everything else is hidden for this profile")
        snapshot("91-limited-home")
    }

    func testRequestEditingIssueRepliesAndPersonalStatistics() {
        app.launchArguments = ["-isolatedStorage", "-sampleIntegrations"]
        app.launch()

        XCTAssertTrue(row("Sample Proxmox VE").waitForExistence(timeout: 10))
        let seerr = row("Sample Seerr")
        reveal(seerr)
        seerr.tap()
        let actions = app.buttons["Actions for Community Garden"]
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        actions.tap()
        app.buttons["Edit Request…"].tap()
        let season3 = app.switches.matching(NSPredicate(format: "label BEGINSWITH %@", "Season 3")).firstMatch
        XCTAssertTrue(season3.waitForExistence(timeout: 10), "The series' seasons are listed")
        XCTAssertTrue(element(containing: "series quota").waitForExistence(timeout: 5), "The requester's quota is shown")
        season3.switches.firstMatch.tap()
        snapshot("84-edit-request")
        app.buttons["Save"].tap()
        XCTAssertTrue(element(containing: "Updated Community Garden").waitForExistence(timeout: 10))

        app.buttons["Issues"].firstMatch.tap()
        let issue = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Night Sky Timelapse")).firstMatch
        XCTAssertTrue(issue.waitForExistence(timeout: 10))
        issue.tap()
        let reply = app.textFields["Reply"]
        XCTAssertTrue(reply.waitForExistence(timeout: 5))
        reply.tap()
        reply.typeText("New subtitle file is in")
        app.buttons["Add Comment"].tap()
        XCTAssertTrue(element(containing: "New subtitle file is in").waitForExistence(timeout: 10), "The reply joins the conversation")
        snapshot("85-issue-conversation")
        app.buttons["Done"].firstMatch.tap()
        back()

        let statistics = app.buttons["Statistics"].firstMatch
        reveal(statistics)
        statistics.tap()
        XCTAssertTrue(element(containing: "Plays per day").waitForExistence(timeout: 10))
        app.buttons["7 days"].firstMatch.tap()
        let person = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Person")).firstMatch
        XCTAssertTrue(person.waitForExistence(timeout: 5))
        choose("Jordan", fromMenu: person)
        XCTAssertTrue(element(containing: "Jordan watch time").waitForExistence(timeout: 10))
        XCTAssertTrue(element(containing: "All time").exists)
        snapshot("86-personal-statistics")
    }

    func testPreviewDiskHistoryTemperaturesLogsAndContainerTemplates() {
        app.launchArguments = ["-previewMode", "-isolatedStorage"]
        app.launch()

        tab("Storage")
        let temperatures = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Temperatures")).firstMatch
        XCTAssertTrue(temperatures.waitForExistence(timeout: 10))
        temperatures.tap()
        XCTAssertTrue(element(containing: "Samsung 990 PRO").waitForExistence(timeout: 10), "Sensors are listed, problems first")
        XCTAssertTrue(element(containing: "Above warning").exists)
        snapshot("27-temperatures")
        back()

        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "System logs")).firstMatch.tap()
        let syslog = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "syslog")).firstMatch
        XCTAssertTrue(syslog.waitForExistence(timeout: 10))
        syslog.tap()
        XCTAssertTrue(element(containing: "temperature above warning threshold").waitForExistence(timeout: 10))
        XCTAssertTrue(element(containing: "of 1,284 lines").exists)
        snapshot("28-system-log")
        back()
        back()

        let disk = row("Disk1")
        for _ in 0..<4 where !disk.exists { app.swipeUp() }
        disk.tap()
        XCTAssertTrue(element(containing: "Usage alerts").waitForExistence(timeout: 10), "Utilisation thresholds are shown as percentages")
        for _ in 0..<3 where !element(containing: "Recorded on this device").exists { app.swipeUp() }
        XCTAssertTrue(element(containing: "Recorded on this device").exists)
        XCTAssertTrue(element(containing: "No new errors since").exists)
        snapshot("29-disk-history")
        back()

        tab("Docker")
        XCTAssertTrue(element(containing: "Port conflicts").waitForExistence(timeout: 10))
        XCTAssertTrue(element(containing: "192.168.1.20:8443/tcp: nextcloud, uptime-kuma").exists)
        row("uptime-kuma").tap()
        for _ in 0..<3 where !element(containing: "No template found").exists { app.swipeUp() }
        XCTAssertTrue(element(containing: "No template found").waitForExistence(timeout: 10), "Orphaned containers are called out")
        snapshot("30-orphaned-container")
        back()
        row("nextcloud").tap()
        for _ in 0..<3 where !element(containing: "my-nextcloud.xml").exists { app.swipeUp() }
        XCTAssertTrue(element(containing: "my-nextcloud.xml").waitForExistence(timeout: 10))
        XCTAssertTrue(element(containing: "Log size").exists)
        snapshot("31-container-template")
    }

    func testNetworkDiagnosticsPoECycleAndHomeAssistantChecks() {
        app.launchArguments = ["-isolatedStorage", "-sampleIntegrations"]
        app.launch()

        XCTAssertTrue(row("Sample Proxmox VE").waitForExistence(timeout: 10))
        let pihole = row("Sample Pi-hole")
        reveal(pihole)
        pihole.tap()
        let diagnostics = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Diagnostics")).firstMatch
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 10))
        diagnostics.tap()
        XCTAssertTrue(element(containing: "telemetry.example-vendor.com").waitForExistence(timeout: 10), "Owners see recent queries")
        XCTAssertTrue(element(containing: "Rate-limiting").exists, "Diagnosis messages are listed")
        let field = app.textFields["Domain to check"]
        field.tap()
        field.typeText("https://ads.example-tracker.net/banner")
        app.buttons["Check"].tap()
        XCTAssertTrue(element(containing: "Blocklist: https://lists.example.org/hosts.txt").waitForExistence(timeout: 10))
        snapshot("32-dns-diagnostics")
        app.buttons["Allow ads.example-tracker.net…"].tap()
        let allow = app.buttons.matching(identifier: "Allow Domain").element(boundBy: 0)
        XCTAssertTrue(allow.waitForExistence(timeout: 5))
        XCTAssertTrue(element(containing: "added to Sample Pi-hole's allowlist as an exact entry").exists, "The confirmation names the consequence")
        allow.tap()
        XCTAssertTrue(element(containing: "ads.example-tracker.net is now allowed.").waitForExistence(timeout: 10))
        back()
        back()

        let unifi = row("Sample UniFi Network")
        reveal(unifi)
        unifi.tap()
        let office = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Office Switch")).firstMatch
        XCTAssertTrue(office.waitForExistence(timeout: 10))
        office.tap()
        let cycle = app.buttons["Power cycle port 1"]
        XCTAssertTrue(cycle.waitForExistence(timeout: 10), "PoE ports offer a power cycle")
        XCTAssertFalse(app.buttons["Power cycle port 6"].exists, "Ports without PoE don't")
        XCTAssertTrue(element(containing: "Uplink").exists)
        snapshot("33-unifi-ports")
        cycle.tap()
        XCTAssertTrue(element(containing: "Port 1 on Office Switch").waitForExistence(timeout: 5), "The confirmation names the port and device")
        app.buttons["Cancel"].firstMatch.tap()
        back()
        back()

        let homeAssistant = row("Sample Home Assistant")
        reveal(homeAssistant)
        homeAssistant.tap()
        let checkConfig = app.buttons["Check Configuration"]
        XCTAssertTrue(checkConfig.waitForExistence(timeout: 10))
        checkConfig.tap()
        XCTAssertTrue(element(containing: "Configuration has errors").waitForExistence(timeout: 10))
        XCTAssertTrue(element(containing: "Integration 'sample_sensor' not found").exists)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Error Log")).firstMatch.tap()
        XCTAssertTrue(element(containing: "Error connecting to MQTT broker").waitForExistence(timeout: 10))
        snapshot("34-home-assistant-error-log")
    }

    func testInfrastructureDiagnosticsProxmoxTrueNASPortainer() {
        app.launchArguments = ["-isolatedStorage", "-sampleIntegrations"]
        app.launch()

        let proxmox = row("Sample Proxmox VE")
        XCTAssertTrue(proxmox.waitForExistence(timeout: 10))
        proxmox.tap()
        let details = app.buttons["Details for pve1"]
        XCTAssertTrue(details.waitForExistence(timeout: 10))
        details.tap()
        XCTAssertTrue(element(containing: "AMD Ryzen 7 5700G").waitForExistence(timeout: 10))
        XCTAssertTrue(element(containing: "UEFI · Secure Boot").exists)
        XCTAssertTrue(element(containing: "Not available").exists, "An offline storage is called out")
        let failingDisk = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "/dev/sdb")).firstMatch
        for _ in 0..<4 where !failingDisk.exists { app.swipeUp() }
        snapshot("35-proxmox-node")
        failingDisk.tap()
        XCTAssertTrue(element(containing: "Reallocated Sector Ct").waitForExistence(timeout: 10))
        XCTAssertTrue(element(containing: "Failing").exists)
        snapshot("36-proxmox-smart")
        back()
        back()
        let failedTask = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "job errors")).firstMatch
        for _ in 0..<6 where !failedTask.exists { app.swipeUp() }
        failedTask.tap()
        XCTAssertTrue(element(containing: "TASK ERROR: job errors").waitForExistence(timeout: 10), "Failed tasks open their log")
        back()
        back()

        let truenas = row("Sample TrueNAS")
        reveal(truenas)
        truenas.tap()
        XCTAssertTrue(element(containing: "Data protection").waitForExistence(timeout: 10))
        let run = app.buttons["Run snapshot task for tank/appdata"]
        for _ in 0..<4 where !run.exists { app.swipeUp() }
        XCTAssertTrue(element(containing: "Dataset tank/photos is locked.").exists, "Task errors are shown")
        run.tap()
        XCTAssertTrue(element(containing: "applies the task's retention (keep 2 weeks)").waitForExistence(timeout: 5), "The confirmation explains retention")
        snapshot("37-truenas-run-snapshot")
        app.buttons["Cancel"].firstMatch.tap()
        back()

        let portainer = row("Sample Portainer")
        reveal(portainer)
        portainer.tap()
        let environment = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "local")).firstMatch
        XCTAssertTrue(environment.waitForExistence(timeout: 10))
        environment.tap()
        let health = app.buttons["Health and restarts for gitea"]
        XCTAssertTrue(health.waitForExistence(timeout: 10))
        health.tap()
        XCTAssertTrue(element(containing: "Failing in a row").waitForExistence(timeout: 10))
        XCTAssertTrue(element(containing: "Connection refused").exists)
        snapshot("38-portainer-health")
    }

    func testArrSystemAndTorrentDiagnostics() {
        app.launchArguments = ["-isolatedStorage", "-sampleIntegrations"]
        app.launch()

        XCTAssertTrue(row("Sample Proxmox VE").waitForExistence(timeout: 10))
        let radarr = row("Sample Radarr")
        reveal(radarr)
        radarr.tap()
        let system = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "System")).firstMatch
        XCTAssertTrue(system.waitForExistence(timeout: 10))
        system.tap()
        XCTAssertTrue(element(containing: "Version 5.27.0.10202 is available").waitForExistence(timeout: 10))
        XCTAssertTrue(element(containing: "Unable to communicate with SABnzbd").exists, "Recent warnings are listed")
        let runBackup = app.buttons["Run Backup"]
        for _ in 0..<4 where !runBackup.exists { app.swipeUp() }
        XCTAssertFalse(app.buttons["Run RSS Sync"].exists, "Tasks that grab releases can't be run from here")
        snapshot("39-arr-system")
        runBackup.tap()
        XCTAssertTrue(element(containing: "backup of the database and settings").waitForExistence(timeout: 5), "The confirmation says what the task does")
        // The list row and the sheet's confirm button share a label; only the sheet's is hittable now.
        let matches = app.buttons.matching(identifier: "Run Backup")
        let confirm = (0..<matches.count).map { matches.element(boundBy: $0) }.last { $0.isHittable }
        XCTAssertNotNil(confirm)
        confirm?.tap()
        for _ in 0..<4 { app.swipeDown() }
        XCTAssertTrue(element(containing: "Backup queued.").waitForExistence(timeout: 10))
        back()
        back()

        let qbt = row("Sample qBittorrent")
        reveal(qbt)
        qbt.tap()
        let torrent = app.buttons["debian-13.1.0-amd64-DVD-1.iso"]
        XCTAssertTrue(torrent.waitForExistence(timeout: 10), "Torrent rows open their diagnostics")
        torrent.tap()
        XCTAssertTrue(element(containing: "backup-tracker.example.net").waitForExistence(timeout: 10))
        XCTAssertTrue(element(containing: "Connection timed out").exists)
        snapshot("40-torrent-trackers")
        app.buttons["Verify Data…"].tap()
        let verify = app.buttons.matching(identifier: "Verify Torrent Data").element(boundBy: 0)
        XCTAssertTrue(verify.waitForExistence(timeout: 5))
        XCTAssertTrue(element(containing: "Nothing is deleted").exists)
        verify.tap()
        XCTAssertTrue(element(containing: "Verification started.").waitForExistence(timeout: 10))
    }

    func testMediaLibraryAuditScreens() {
        app.launchArguments = ["-isolatedStorage", "-sampleIntegrations"]
        app.launch()

        XCTAssertTrue(row("Sample Proxmox VE").waitForExistence(timeout: 10))
        let jellyfin = row("Sample Jellyfin")
        reveal(jellyfin)
        jellyfin.tap()
        let logs = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Server Logs")).firstMatch
        for _ in 0..<12 where !logs.exists { app.swipeUp() }
        XCTAssertTrue(element(containing: "Failed to load").exists, "Plugins that didn't load are flagged")
        snapshot("41-jellyfin-plugins")
        logs.tap()
        let file = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "log_20260929.log")).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        file.tap()
        XCTAssertTrue(element(containing: "api_key=[redacted]").waitForExistence(timeout: 10), "Keys in log lines are masked")
        snapshot("42-jellyfin-log")
        back()
        back()
        back()

        let tautulli = row("Sample Tautulli")
        reveal(tautulli)
        tautulli.tap()
        let delivery = element(containing: "3 of the latest 25 failed")
        for _ in 0..<10 where !delivery.exists { app.swipeUp() }
        XCTAssertTrue(delivery.exists, "Failed notification deliveries are summarised")
        XCTAssertTrue(element(containing: "Discord notification failed").exists)
        snapshot("43-tautulli-problems")
        back()

        let komga = row("Sample Komga")
        reveal(komga)
        komga.tap()
        let update = element(containing: "Version 1.29.0 is available")
        for _ in 0..<4 where !update.exists { app.swipeUp() }
        XCTAssertTrue(update.waitForExistence(timeout: 10))
        back()

        let abs = row("Sample Audiobookshelf")
        reveal(abs)
        abs.tap()
        let create = app.buttons["Create Backup…"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        let stale = element(containing: "Last backup")
        for _ in 0..<8 where !stale.exists { app.swipeUp() }
        XCTAssertTrue(stale.exists, "Backup recency is shown")
        for _ in 0..<8 where !create.isHittable { app.swipeDown() }
        create.tap()
        XCTAssertTrue(element(containing: "writes a new backup file").waitForExistence(timeout: 5), "The confirmation says what happens")
        snapshot("44-abs-backup-confirmation")
        app.buttons["Cancel"].firstMatch.tap()
    }
}
