import AppKit
import XCTest
@testable import OutputLens

final class ApplicationMenuTests: XCTestCase {
    func testEditMenuProvidesStandardTextEditingCommands() throws {
        let menu = ApplicationMenu.make()
        let editMenu = try XCTUnwrap(menu.items.first?.submenu)

        XCTAssertNotNil(item(in: editMenu, action: #selector(NSText.selectAll(_:)), key: "a"))
        XCTAssertNotNil(item(in: editMenu, action: #selector(NSText.cut(_:)), key: "x"))
        XCTAssertNotNil(item(in: editMenu, action: #selector(NSText.copy(_:)), key: "c"))
        XCTAssertNotNil(item(in: editMenu, action: #selector(NSText.paste(_:)), key: "v"))
        XCTAssertNotNil(item(in: editMenu, action: Selector(("undo:")), key: "z"))

        let redo = try XCTUnwrap(item(in: editMenu, action: Selector(("redo:")), key: "z"))
        XCTAssertEqual(redo.keyEquivalentModifierMask, [.command, .shift])
    }

    private func item(in menu: NSMenu, action: Selector, key: String) -> NSMenuItem? {
        menu.items.first { $0.action == action && $0.keyEquivalent == key }
    }
}
