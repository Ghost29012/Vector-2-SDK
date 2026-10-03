//
//  Vector2_level_editorApp.swift
//  Vector2 level editor
//
//  Created by Ghosted on 2026-04-22.
//

import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}

@main
struct Vector2_level_editorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1520, height: 920)
        .commands {
            CommandGroup(replacing: .pasteboard) {
                Button("Copy") {
                    if Self.isTextInputFocused {
                        NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                    } else {
                        NotificationCenter.default.post(name: .vector2EditorCopyRequested, object: nil)
                    }
                }
                .keyboardShortcut("c", modifiers: .command)

                Button("Paste") {
                    if Self.isTextInputFocused {
                        NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                    } else {
                        NotificationCenter.default.post(name: .vector2EditorPasteRequested, object: nil)
                    }
                }
                .keyboardShortcut("v", modifiers: .command)
            }
        }
    }

    private static var isTextInputFocused: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSTextView || responder is NSTextField || responder is NSSearchField
    }
}
