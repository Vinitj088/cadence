import SwiftUI

/// SwiftUI's `@State` is a macro in the macOS 27 SDK, and its plugin ships only with full Xcode.
/// Aliasing the underlying property wrapper lets Cadence build with just the Command Line Tools.
typealias ViewState<Value> = SwiftUI.State<Value>
