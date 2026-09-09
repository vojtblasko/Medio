import XCTest

@MainActor
final class MedioUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func wait(_ element: XCUIElement, timeout: TimeInterval = 5.0, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), file: file, line: line)
    }

    private func makeApp(reset: Bool = true, arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-medioUITestMode"] + (reset ? ["-medioUITestReset"] : []) + arguments
        app.launchEnvironment["UITEST_DISABLE_ANIMATIONS"] = "1"
        return app
    }

    func testHomePanelsAndFolderFlow() {
        let app = makeApp()
        app.launch()

        wait(app.buttons["Home Options"])
        wait(app.buttons["Example Folder"])

        app.buttons["Home Options"].tap()
        wait(app.buttons["Settings"])
        app.buttons["Settings"].tap()
        wait(app.switches["settings_internet_access"])
        wait(app.buttons["sheet_close"])
        app.buttons["sheet_close"].tap()
        wait(app.buttons["Example Folder"])

        app.buttons["Example Folder"].tap()
        wait(app.buttons["Folder Options"])
        app.buttons["BackButton"].tap()

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
        app.buttons["BackButton"].tap()
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
        wait(app.buttons["Song Two"])
        app.buttons["Song Two"].tap()

        wait(app.buttons["Now Playing"])
        app.buttons["Now Playing"].tap()
        wait(app.buttons["now_playing_close"])
        app.buttons["now_playing_close"].tap()

        app.buttons["BackButton"].tap()
        wait(app.buttons["Example Artist"])
        app.buttons["Example Artist"].tap()
        wait(app.buttons["Artist Options"])
        app.buttons["BackButton"].tap()
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
        app.buttons["Example Folder"].tap()
        wait(app.buttons["Example Folder"])
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
        app.buttons["sheet_close"].tap()
        wait(app.buttons["Folder Options"])
        app.buttons["BackButton"].tap()

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

        XCTAssertLessThan(abs(title.frame.midY - options.frame.midY), 12)
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
