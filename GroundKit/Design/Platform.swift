import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// The iPhone, iPad and Mac apps share one target. iOS-only APIs are wrapped here, so the
// views read the same on every platform; each wrapper does the iOS thing on iOS.

#if canImport(UIKit)
typealias PlatformColor = UIColor
typealias PlatformEdgeInsets = UIEdgeInsets
#else
typealias PlatformColor = NSColor
typealias PlatformEdgeInsets = NSEdgeInsets
#endif

extension PlatformColor {
    /// An sRGB colour from 0xRRGGBB.
    static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> PlatformColor {
        let r = CGFloat((hex >> 16) & 0xFF) / 255, g = CGFloat((hex >> 8) & 0xFF) / 255, b = CGFloat(hex & 0xFF) / 255
        #if canImport(UIKit)
        return UIColor(red: r, green: g, blue: b, alpha: alpha)
        #else
        return NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
        #endif
    }
}

extension Color {
    init(platform color: PlatformColor) {
        #if canImport(UIKit)
        self.init(uiColor: color)
        #else
        self.init(nsColor: color)
        #endif
    }
}

extension ToolbarItemPlacement {
    /// The leading end of the navigation bar; the window toolbar's leading end on the Mac.
    static var barLeading: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .navigation
        #endif
    }

    /// The trailing end of the navigation bar; the window toolbar's trailing end on the Mac.
    static var barTrailing: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .primaryAction
        #endif
    }
}

extension SearchFieldPlacement {
    /// Always shown under the title on iOS; in the toolbar on the Mac.
    static var alwaysVisible: SearchFieldPlacement {
        #if os(iOS)
        .navigationBarDrawer(displayMode: .always)
        #else
        .automatic
        #endif
    }
}

/// Smallest size of a sheet that stands in for a full-screen cover on the Mac.
let macCoverSize = CGSize(width: 960, height: 680)

extension View {
    /// A small, centred title (iOS). The Mac shows the title in the window toolbar.
    func inlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// Full screen on iOS; a large sheet on the Mac, which has no full-screen cover.
    func coverScreen<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented, content: content)
        #else
        sheet(isPresented: isPresented) {
            content().frame(minWidth: macCoverSize.width, minHeight: macCoverSize.height)
        }
        #endif
    }

    /// Grouped rows with margins (iOS); the inset list on the Mac.
    func groupedListStyle() -> some View {
        #if os(iOS)
        listStyle(.insetGrouped)
        #else
        listStyle(.inset)
        #endif
    }

    /// An email field: email keyboard, no automatic capitals.
    func emailEntry() -> some View {
        #if os(iOS)
        keyboardType(.emailAddress).textInputAutocapitalization(.never)
        #else
        self
        #endif
    }

    /// A web address field: URL keyboard, no automatic capitals.
    func urlEntry() -> some View {
        #if os(iOS)
        keyboardType(.URL).textInputAutocapitalization(.never)
        #else
        self
        #endif
    }

    /// Codes typed in capitals: flight numbers, registrations, airports, stands.
    func capitalsEntry() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.characters)
        #else
        self
        #endif
    }
}

/// Keep screen on: stops the display sleeping while the app is in use.
enum ScreenAwake {
    #if os(macOS)
    private static var activity: NSObjectProtocol?
    #endif

    static func set(_ on: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = on
        #else
        if on, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Keep screen on is set in GroundKit")
        } else if !on, let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
        #endif
    }
}
