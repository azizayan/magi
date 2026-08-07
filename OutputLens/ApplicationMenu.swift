import AppKit

enum ApplicationMenu {
    static func make() -> NSMenu {
        let mainMenu = NSMenu()

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(command("Undo", action: Selector(("undo:")), key: "z"))
        editMenu.addItem(command("Redo", action: Selector(("redo:")), key: "z", modifiers: [.command, .shift]))
        editMenu.addItem(.separator())
        editMenu.addItem(command("Cut", action: #selector(NSText.cut(_:)), key: "x"))
        editMenu.addItem(command("Copy", action: #selector(NSText.copy(_:)), key: "c"))
        editMenu.addItem(command("Paste", action: #selector(NSText.paste(_:)), key: "v"))
        editMenu.addItem(command("Select All", action: #selector(NSText.selectAll(_:)), key: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        return mainMenu
    }

    private static func command(
        _ title: String,
        action: Selector,
        key: String,
        modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}
