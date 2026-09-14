import XCTest

@MainActor
final class MedioUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func wait(_ element: XCUIElement, timeout: TimeInterval = 5.0, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), file: file, line: line)
    }

    private func goBack(_ app: XCUIApplication, to previousTitle: String) {
        // UIKit's private BackButton identifier is absent on some iOS versions.
        // Scope the public previous-screen label to navigation bars to avoid tabs.
        let button = app.navigationBars.buttons.matching(
            NSPredicate(format: "identifier == %@ OR label == %@", "BackButton", previousTitle)
        ).firstMatch
        if button.exists { button.tap() }
        else {
            let close = app.buttons["sheet_close"]
            wait(close)
            XCTAssertTrue(close.isHittable)
            close.tap()
        }
    }

    private func tapVisibleButton(_ app: XCUIApplication, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let matches = app.buttons.matching(NSPredicate(format: "label == %@ OR identifier == %@", label, label))
        guard let button = matches.allElementsBoundByIndex.first(where: { $0.isHittable }) else {
            XCTFail("No visible button: \(label)", file: file, line: line)
            return
        }
        button.tap()
    }

    private func makeApp(reset: Bool = true, arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-medioUITestMode"] + (reset ? ["-medioUITestReset"] : []) + arguments
        app.launchEnvironment["UITEST_DISABLE_ANIMATIONS"] = "1"
        return app
    }

    func testEncryptionSetupRemainsOpenDuringPlayback() {
        let app = makeApp(arguments: ["-medioStartFirstPlayable", "-medioInitialRoute", "settings"])
        app.launch()
        let setup = app.buttons["sharing_encryption_setup"]
        for _ in 0..<6 where !setup.exists || !setup.isHittable { app.swipeUp() }
        wait(setup)
        setup.tap()
        wait(app.navigationBars["Encrypted Sharing"])
        // Exercise the page across playback updates and scrolling, which dismissed
        // the old Section-owned presentation.
        app.swipeUp()
        app.swipeDown()
        XCTAssertTrue(app.navigationBars["Encrypted Sharing"].exists)
        XCTAssertFalse(app.tabBars.buttons["Home"].isHittable)
        goBack(app, to: "Settings")
        wait(app.navigationBars["Settings"])
    }

    func testUnpinnedFavoritesRemainAccessibleInHomeFiles() {
        let app = makeApp()
        app.launch()
        wait(app.buttons["Song One"])
        app.buttons["Song One"].tap()
        app.buttons["Now Playing"].tap()
        wait(app.buttons["Add Favorite"])
        app.buttons["Add Favorite"].tap()
        wait(app.buttons["Remove Favorite"])
        app.buttons["now_playing_close"].tap()
        app.buttons["Home Options"].tap()
        app.buttons["Settings"].tap()
        let priority = app.switches["settings_priority_favorites"]
        for _ in 0..<10 where !priority.exists || !priority.isHittable { app.swipeUp() }
        wait(priority)
        priority.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(priority.value as? String, "0")
        app.buttons["sheet_close"].tap()
        wait(app.buttons["Favorites"])
        app.buttons["Favorites"].tap()
        wait(app.navigationBars["Favorites"])
        wait(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Song One")).firstMatch)
        XCTAssertTrue(app.tabBars.buttons["Library"].isHittable)
    }

    func testHomePanelsAndFolderFlow() {
        let app = makeApp()
        app.launch()

        wait(app.buttons["Home Options"])
        wait(app.buttons["Example Folder"])

        app.buttons["Home Options"].tap()
        wait(app.buttons["Settings"])
        app.buttons["Settings"].tap()
        let internetAccess = app.switches["settings_internet_access"]
        for _ in 0..<5 where !internetAccess.exists || !internetAccess.isHittable { app.swipeUp() }
        wait(internetAccess)
        wait(app.buttons["sheet_close"])
        app.buttons["sheet_close"].tap()
        wait(app.buttons["Example Folder"])

        app.buttons["Example Folder"].tap()
        wait(app.buttons["Folder Options"])
        XCTAssertTrue(app.tabBars.buttons["Library"].isHittable)
        goBack(app, to: "Home")

        app.buttons["Song One"].tap()
        wait(app.buttons["Now Playing"])
        app.buttons["Now Playing"].tap()
        wait(app.buttons["now_playing_close"])
        app.buttons["now_playing_close"].tap()
        wait(app.buttons["Home Options"])
    }

    func testPlaybackQueueAndNowPlayingFromHome() {
        let app = makeApp()
        app.launch()

        wait(app.buttons["Song One"])

        app.buttons["Song One"].tap()
        wait(app.buttons["Now Playing"])
        app.buttons["Now Playing"].tap()
        wait(app.buttons["now_playing_queue"])

        app.buttons["now_playing_queue"].tap()
        wait(app.navigationBars["Queue"])
        wait(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Song One")).firstMatch)
        goBack(app, to: "Back")
        wait(app.buttons["now_playing_close"])
        app.buttons["now_playing_close"].tap()
    }

    func testLibraryTabAlbumAndArtistPanels() {
        let app = makeApp()
        app.launch()

        // Switch to Library tab and open album/artist sheets.
        wait(app.tabBars.buttons["Library"])
        app.tabBars.buttons["Library"].tap()

        wait(app.buttons["Example Album"])
        app.buttons["Example Album"].tap()
        wait(app.navigationBars["Example Album"])
        XCTAssertTrue(app.tabBars.buttons["Home"].isHittable)
        // The tab bar reduces the initial viewport; scroll past the full-size cover.
        for _ in 0..<5 where !app.buttons["Song Two"].isHittable { app.swipeUp() }
        tapVisibleButton(app, "Song Two")

        wait(app.buttons["Now Playing"])
        tapVisibleButton(app, "Now Playing")
        wait(app.buttons["now_playing_close"])
        app.buttons["now_playing_close"].tap()

        goBack(app, to: "Library")
        wait(app.buttons["Example Artist"])
        app.buttons["Example Artist"].tap()
        wait(app.buttons["Artist Options"])
        goBack(app, to: "Library")
    }

    func testMenuRemainsClickableDuringPlaybackAndDetailScreensHideTabs() {
        let app = makeApp()
        app.launch()
        wait(app.buttons["Song One"])
        app.buttons["Song One"].tap()
        let options = app.buttons["Home Options"]
        wait(options)
        XCTAssertEqual(options.frame.width, options.frame.height, accuracy: 2)
        XCTAssertGreaterThanOrEqual(options.frame.width, 44)
        let circle = XCTAttachment(screenshot: app.screenshot())
        circle.name = "Circular Home options during playback"
        circle.lifetime = .keepAlways
        add(circle)
        options.tap()
        let icons = app.buttons["Icons"]
        wait(icons)
        // Hold the menu open across several playback progress publications.
        let stillOpen = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: icons)
        XCTAssertEqual(XCTWaiter.wait(for: [stillOpen], timeout: 2), .completed)
        icons.press(forDuration: 1.2)
        wait(app.buttons["file_item_Example Folder"])
        let grid = XCTAttachment(screenshot: app.screenshot())
        grid.name = "Uniform icon grid and white progress"; grid.lifetime = .keepAlways; add(grid)
        options.tap()
        app.buttons["Settings"].tap()
        wait(app.navigationBars["Settings"])
        XCTAssertFalse(app.tabBars.buttons["Home"].exists && app.tabBars.buttons["Home"].isHittable)
        app.buttons["sheet_close"].tap()
        app.buttons["Now Playing"].tap()
        wait(app.buttons["now_playing_queue"])
        XCTAssertFalse(app.tabBars.buttons["Home"].exists && app.tabBars.buttons["Home"].isHittable)
        app.buttons["now_playing_queue"].tap()
        wait(app.navigationBars["Queue"])
        XCTAssertFalse(app.tabBars.buttons["Home"].exists && app.tabBars.buttons["Home"].isHittable)
        goBack(app, to: "Back")
        app.buttons["now_playing_close"].tap()
        XCTAssertTrue(app.tabBars.buttons["Home"].isHittable)
    }

    func testHomeAndLibraryOptionMenus() {
        let app = makeApp()
        app.launch()

        wait(app.buttons["Home Options"])
        app.buttons["Home Options"].tap()
        for title in ["Select", "New Folder", "Import Files", "Icons", "List", "Desktop Style", "View Options"] {
            wait(app.buttons[title])
        }
        for title in ["Name", "Kind", "Date Modified", "Release Date", "Size"] {
            wait(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch)
        }

        app.buttons["View Options"].tap()
        wait(app.navigationBars["View Options"])
        wait(app.sliders["browser_icon_size"])
        app.buttons["Done"].tap()

        app.buttons["Home Options"].tap()
        app.buttons["Icons"].tap()
        wait(app.tabBars.buttons["Library"])
        app.tabBars.buttons["Library"].tap()
        wait(app.buttons["Library Options"])
        app.buttons["Library Options"].tap()
        for title in ["Select", "New Folder", "Import Files"] {
            wait(app.buttons[title])
        }
        XCTAssertFalse(app.buttons["Icons"].exists)
        XCTAssertFalse(app.buttons["List"].exists)
        for title in ["Name", "Kind", "Date Modified", "Release Date", "Size"] {
            wait(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch)
        }
    }

    func testHomeIconLongPressCanSelectOneTile() {
        let app = makeApp()
        app.launch()

        wait(app.buttons["Home Options"])
        app.buttons["Home Options"].tap()
        wait(app.buttons["Icons"])
        app.buttons["Icons"].tap()

        let tile = app.buttons["file_item_Example Folder"]
        wait(tile)
        tile.press(forDuration: 1)

        wait(app.buttons["Select"])
        app.buttons["Select"].tap()
        wait(app.buttons["Done"])
    }

    func testPriorityCardsStayAlignedAcrossHomeViewStyles() {
        let app = makeApp(arguments: [
            "-medio.settings.priorityFoldersCount", "4",
            "-medio.settings.favoritesHomeFolderEnabled", "NO",
            "-medio.settings.prioritySlotArtworkPaths", "{ primary = \"/missing/priority-preview.png\"; }",
            "-medio.settings.prioritySlotImageOnlyKeys", "(primary)"
        ])
        app.launch()

        for style in ["List", "Icons", "Desktop Style"] {
            wait(app.buttons["Home Options"])
            if style != "List" {
                app.buttons["Home Options"].tap()
                wait(app.buttons[style])
                app.buttons[style].tap()
            }

            let cards = (1...4).map { app.buttons["Choose priority folder \($0)"] }
            cards.forEach { wait($0) }
            let frames = cards.map(\.frame)
            XCTAssertEqual(frames[0].minY, frames[1].minY, accuracy: 1, style)
            XCTAssertEqual(frames[2].minY, frames[3].minY, accuracy: 1, style)
            XCTAssertEqual(frames[0].minX, frames[2].minX, accuracy: 1, style)
            XCTAssertEqual(frames[1].minX, frames[3].minX, accuracy: 1, style)
            XCTAssertEqual(frames[2].minY - frames[0].maxY, 12, accuracy: 1, style)
            for frame in frames {
                XCTAssertEqual(frame.height, frames[0].height, accuracy: 1, style)
                XCTAssertEqual(frame.width, frames[0].width, accuracy: 1, style)
            }

            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Priority cards - \(style)"
            screenshot.lifetime = .keepAlways
            add(screenshot)

            cards[2].press(forDuration: 1)
            wait(app.buttons["Choose Folder"])
            app.buttons["Choose Folder"].tap()
            wait(app.navigationBars["Priority Folder"])
            app.buttons["sheet_close"].tap()
        }

        // A slot whose saved image disappeared must also behave like a normal folder slot.
        app.buttons["Choose priority folder 1"].tap()
        wait(app.navigationBars["Priority Folder"])
        app.buttons["Example Folder, Example Folder"].tap()
        wait(app.buttons["Home Options"])
        XCTAssertFalse(app.buttons["Choose priority folder 1"].exists)
    }

    func testPriorityImageCardKeepsFolderDimensionsInEveryViewStyle() {
        let app = makeApp(arguments: ["-medioUITestPriorityImage"])
        app.launch()
        for style in ["List", "Icons", "Desktop Style"] {
            wait(app.buttons["Home Options"])
            app.buttons["Home Options"].tap()
            app.buttons[style].tap()
            let imageCard = app.buttons["Choose priority folder 2"]
            let folderCard = app.buttons["Choose priority folder 3"]
            wait(imageCard); wait(folderCard)
            XCTAssertEqual(imageCard.frame.width, folderCard.frame.width, accuracy: 1, style)
            XCTAssertEqual(imageCard.frame.height, folderCard.frame.height, accuracy: 1, style)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Image and folder cards - \(style)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
    }

    func testPriorityImageCropMatchesCardAndSavesWithoutGrowing() {
        let app = makeApp(arguments: ["-medioUITestPriorityImage"])
        app.launch()
        let card = app.buttons["Choose priority folder 2"]
        wait(card)
        let originalFrame = card.frame
        card.press(forDuration: 1)
        app.buttons["Make Image"].tap()
        app.buttons["Change Image"].tap()
        app.buttons["Choose from Files"].tap()
        let browse = app.buttons["Browse"].firstMatch
        if browse.waitForExistence(timeout: 3), !browse.isSelected { browse.tap() }
        let file = app.cells.matching(NSPredicate(format: "label CONTAINS %@", "Priority Test Image")).firstMatch
        if !file.waitForExistence(timeout: 3) {
            let onDevice = app.cells.matching(NSPredicate(format: "label CONTAINS %@", "On My iPhone")).firstMatch
            if onDevice.exists { onDevice.tap() }
            else if app.staticTexts["On My iPhone"].exists { app.staticTexts["On My iPhone"].tap() }
            let medio = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", "Medio")).firstMatch
            wait(medio); medio.tap()
        }
        wait(file)
        // In Files' icon view the cell's center can fall between its preview and
        // filename. Target the visible filename after navigation has settled.
        let filename = file.staticTexts["Priority Test Image"].firstMatch
        wait(filename)
        let canTapFilename = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: filename)
        XCTAssertEqual(XCTWaiter.wait(for: [canTapFilename], timeout: 5), .completed)
        filename.tap()
        let pickerDismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: file)
        XCTAssertEqual(XCTWaiter.wait(for: [pickerDismissed], timeout: 10), .completed, "Selecting the image must dismiss the Files picker")
        wait(app.navigationBars["Crop Cover"])
        let crop = app.images["cover_crop_viewport"]
        wait(crop)
        XCTAssertEqual(crop.frame.width / crop.frame.height, originalFrame.width / originalFrame.height, accuracy: 0.03)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Priority image rectangular crop"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Use Image"].tap()
        wait(app.buttons["Change Image"])
        app.buttons["sheet_close"].tap()
        wait(card)
        XCTAssertEqual(card.frame.width, originalFrame.width, accuracy: 1)
        XCTAssertEqual(card.frame.height, originalFrame.height, accuracy: 1)
    }

    func testNativeSortDirectionChangesOnReselection() {
        let app = makeApp()
        app.launch()
        app.buttons["Home Options"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Name")).firstMatch.tap()
        app.buttons["Home Options"].tap()
        wait(app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", ", Ascending")).firstMatch)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Native sort menu - Ascending"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Name")).firstMatch.tap()
        app.buttons["Home Options"].tap()
        wait(app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", ", Descending")).firstMatch)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Kind")).firstMatch.tap()
        app.buttons["Home Options"].tap()
        wait(app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", ", Ascending")).firstMatch)
    }

    func testQueueShowsRepeatSongAndQueueModes() {
        let app = makeApp()
        app.launch()
        app.buttons["Song One"].tap()
        app.buttons["Now Playing"].tap()
        wait(app.buttons["now_playing_repeat"])
        app.buttons["now_playing_repeat"].tap()
        app.buttons["now_playing_queue"].tap()
        wait(app.navigationBars["Queue"])
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "queue_item_", "Song One")).firstMatch.value as? String, "Loop song")
        XCTAssertFalse(app.otherElements["queue_repeat_all"].exists)
        goBack(app, to: "Back")
        app.buttons["now_playing_repeat"].tap()
        app.buttons["now_playing_queue"].tap()
        wait(app.staticTexts["Loop queue"])
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Queue with repeat indicator"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testNewPlaybackOnlineAndFavoritesSettingsAreAccessible() {
        let app = makeApp()
        app.launch()
        app.buttons["Home Options"].tap()
        app.buttons["Settings"].tap()
        wait(app.navigationBars["Settings"])
        let songs = app.buttons["settings_indicator_songs"]
        wait(songs)
        XCTAssertEqual(songs.value as? String, "Selected")
        songs.tap()
        XCTAssertEqual(songs.value as? String, "Not selected")
        XCTAssertEqual(app.buttons["settings_indicator_albums"].value as? String, "Selected")
        XCTAssertEqual(app.buttons["settings_indicator_artists"].value as? String, "Selected")
        let internet = app.switches["settings_internet_access"]
        if !internet.isHittable { app.swipeUp() }
        wait(internet)
        XCTAssertEqual(internet.value as? String, "0")
        internet.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(internet.value as? String, "1")
        for feature in ["artistLookup", "imageMetadata", "imageDownloads"] {
            let row = app.descendants(matching: .any)["settings_online_\(feature)"].firstMatch
            for _ in 0..<4 where !row.exists || !row.isHittable { app.swipeUp() }
            wait(row)
            XCTAssertFalse(app.switches["settings_online_\(feature)"].exists)
        }
        let priority = app.switches["settings_priority_favorites"]
        for _ in 0..<5 where !priority.exists || !priority.isHittable { app.swipeUp() }
        wait(priority)
        XCTAssertFalse(app.switches["settings_home_favorites"].exists)
        priority.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(priority.value as? String, "0")
    }

    func testPriorityImagePickersPresentAboveTheOpenPanel() {
        let app = makeApp()
        app.launch()
        let card = app.buttons["Choose priority folder 2"]
        wait(card)
        card.press(forDuration: 1)
        wait(app.buttons["Make Image"])
        app.buttons["Make Image"].tap()
        wait(app.navigationBars["Make Priority Image"])

        for source in ["Choose from Files", "Choose from Photos"] {
            app.buttons["Choose Image"].tap()
            wait(app.buttons[source])
            app.buttons[source].tap()
            let cancel = app.buttons["Cancel"].firstMatch
            wait(cancel)
            XCTAssertTrue(cancel.isHittable)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Priority image picker - \(source)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            cancel.tap()
            wait(app.buttons["Choose Image"])
            XCTAssertTrue(app.buttons["Choose Image"].isHittable)
            XCTAssertFalse(app.alerts["Priority Image"].exists)
        }
    }

    func testHomeDesktopStyleLongPressCanSelectOneTile() {
        let app = makeApp()
        app.launch()

        wait(app.buttons["Home Options"])
        app.buttons["Home Options"].tap()
        wait(app.buttons["Desktop Style"])
        app.buttons["Desktop Style"].tap()

        let tile = app.buttons["file_item_Example Folder"]
        wait(tile)
        tile.press(forDuration: 1)

        wait(app.buttons["Select"])
        app.buttons["Select"].tap()
        wait(app.buttons["Done"])
    }

    func testHomeDesktopStyleFreePositionPersistsAfterRelaunch() {
        let app = makeApp()
        app.launch()

        wait(app.buttons["Home Options"])
        app.buttons["Home Options"].tap()
        wait(app.buttons["Desktop Style"])
        app.buttons["Desktop Style"].tap()

        let tile = app.buttons["file_item_Example Folder"]
        wait(tile)

        let originalFrame = tile.frame
        let destinationY = originalFrame.midY > app.frame.midY ? 0.38 : 0.68
        let destination = app.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: destinationY))
        tile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: destination)

        let movedTile = app.buttons["file_item_Example Folder"]
        let moved = NSPredicate { _, _ in
            hypot(
                movedTile.frame.midX - originalFrame.midX,
                movedTile.frame.midY - originalFrame.midY
            ) > 80
        }
        expectation(for: moved, evaluatedWith: movedTile)
        waitForExpectations(timeout: 5)
        let movedFrame = movedTile.frame

        app.terminate()
        let relaunchedApp = makeApp(reset: false)
        relaunchedApp.launch()
        let relaunchedTile = relaunchedApp.buttons["file_item_Example Folder"]
        wait(relaunchedTile)
        let restored = NSPredicate { _, _ in
            abs(relaunchedTile.frame.midX - movedFrame.midX) <= 4
                && abs(relaunchedTile.frame.midY - movedFrame.midY) <= 4
        }
        expectation(for: restored, evaluatedWith: relaunchedTile)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(relaunchedTile.frame.midX, movedFrame.midX, accuracy: 4)
        XCTAssertEqual(relaunchedTile.frame.midY, movedFrame.midY, accuracy: 4)
    }

    func testFolderCreateValidationAndNowPlayingNavigation() {
        let app = makeApp()
        app.launch()

        wait(app.buttons["Example Folder"])
        app.buttons["Example Folder"].tap()
        wait(app.buttons["Folder Options"])
        app.buttons["Folder Options"].tap()
        wait(app.buttons["New Folder"])
        app.buttons["New Folder"].tap()

        wait(app.buttons["Create"])
        app.buttons["Create"].tap()
        wait(app.staticTexts["Folder name cannot be empty."])
        goBack(app, to: "Example Folder")
        wait(app.buttons["Folder Options"])
        goBack(app, to: "Home")

        app.buttons["Example Video"].tap()
        wait(app.buttons["Now Playing"])
        app.buttons["Now Playing"].tap()
        wait(app.buttons["now_playing_close"])
        app.buttons["now_playing_close"].tap()
        wait(app.buttons["Home Options"])
    }

    func testCreateFolderRetainsTypedName() {
        let app = makeApp()
        app.launch()

        wait(app.buttons["Home Options"])
        app.buttons["Home Options"].tap()
        wait(app.buttons["New Folder"])
        app.buttons["New Folder"].tap()

        let folderName = app.textFields["Folder name"]
        wait(folderName)
        folderName.tap()
        folderName.typeText("Device Keyboard Test")

        XCTAssertEqual(folderName.value as? String, "Device Keyboard Test")
    }

    func testLaunchPerformanceBaseline() {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let app = makeApp()
            app.launch()
            app.terminate()
        }
    }

    func testHomeScrollingClockAndMemoryBaseline() {
        let app = makeApp()
        app.launch()
        wait(app.buttons["Home Options"])

        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()]) {
            app.swipeUp(velocity: .fast)
            app.swipeDown(velocity: .fast)
        }
    }

    func testRootChromeAlignsCollapsesAndRestoresSearch() {
        let app = makeApp(arguments: ["-medioUITestLongLibrary"])
        app.launch()

        let navigationBar = app.navigationBars["Home"]
        let title = navigationBar.staticTexts["Home"]
        let options = app.buttons["Home Options"]
        let search = app.searchFields["Search"]
        wait(navigationBar)
        wait(title)
        wait(options)
        wait(search)

        XCTAssertLessThanOrEqual(abs(title.frame.midY - options.frame.midY), 12)
        XCTAssertLessThan(title.frame.minX, app.frame.midX)
        let expandedTitleHeight = title.frame.height
        XCTAssertTrue(search.isHittable)

        app.swipeUp(velocity: .fast)
        let collapsed = NSPredicate { _, _ in
            title.frame.height < expandedTitleHeight - 8 && !search.isHittable
        }
        expectation(for: collapsed, evaluatedWith: title)
        waitForExpectations(timeout: 5)

        app.swipeDown(velocity: .fast)
        let restored = NSPredicate { _, _ in
            title.frame.height >= expandedTitleHeight - 2 && search.isHittable
        }
        expectation(for: restored, evaluatedWith: title)
        waitForExpectations(timeout: 5)
    }

}

extension MedioUITests {
    func testDefaultLanguagesTranslateHomeMenusAndSettings() {
        let languages = [
            ("en", "en_US", "Home", "Home Options", "Settings", "Ascending", "Name"),
            ("cs", "cs_CZ", "Domů", "Možnosti úvodní stránky", "Nastavení", "Vzestupně", "Název"),
            ("de", "de_DE", "Start", "Startoptionen", "Einstellungen", "Aufsteigend", "Name"),
            ("fr", "fr_FR", "Accueil", "Options de l’accueil", "Réglages", "Croissant", "Nom"),
            ("fr-CA", "fr_CA", "Accueil", "Options de l’accueil", "Réglages", "Croissant", "Nom"),
            ("bg", "bg_BG", "Начало", "Опции за началната страница", "Настройки", "Възходящо", "Име"),
            ("sk", "sk_SK", "Domov", "Možnosti úvodnej stránky", "Nastavenia", "Vzostupne", "Názov")
        ]
        for (language, locale, home, options, settings, ascending, name) in languages {
            let app = makeApp(arguments: ["-AppleLanguages", "(\(language))", "-AppleLocale", locale])
            app.launch()
            wait(app.tabBars.buttons[home])
            wait(app.navigationBars[home])
            XCTAssertFalse(language != "en" && app.navigationBars["Home"].exists)
            wait(app.buttons[options])
            app.buttons[options].tap()
            wait(app.buttons[settings])
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch.tap()
            app.buttons[options].tap()
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", ascending)).firstMatch.exists)
            let menu = XCTAttachment(screenshot: app.screenshot())
            menu.name = "\(language)-native-menu"; menu.lifetime = .keepAlways; add(menu)
            app.buttons[settings].tap()
            wait(app.switches["settings_audio_sharing"])
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "\(language)-settings"; screenshot.lifetime = .keepAlways; add(screenshot)
            app.terminate()
        }
    }

    func testNowPlayingControlsSitLowerAndStayReachable() {
        let app = makeApp(arguments: ["-medioStartFirstPlayable", "-medioInitialRoute", "nowplaying", "-AppleLanguages", "(en)"])
        app.launch()
        let repeatButton = app.buttons["now_playing_repeat"]
        wait(repeatButton)
        XCTAssertTrue(repeatButton.isHittable)
        XCTAssertGreaterThan(repeatButton.frame.midY, app.frame.height * 0.75)
        XCTAssertLessThan(repeatButton.frame.maxY, app.frame.height - 20)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "now-playing-lower-controls"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
