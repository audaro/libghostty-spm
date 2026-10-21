//
//  TerminalMousePressureStage.swift
//  libghostty-spm
//

/// The stage `ghostty_surface_mouse_pressure` takes, which the C header
/// passes as a bare `uint32_t`. The values are ghostty's own
/// `input.MousePressureStage` (src/input/mouse.zig), which the C entry point
/// converts with `std.enums.fromInt` and drops if it does not recognise.
public enum TerminalMousePressureStage: UInt32, Sendable {
    /// The pointer is not pressed.
    case none = 0
    /// Pressed a normal amount: on a macOS trackpad, after the click.
    case normal = 1
    /// Pressed a deep amount: a force click.
    case deep = 2
}
