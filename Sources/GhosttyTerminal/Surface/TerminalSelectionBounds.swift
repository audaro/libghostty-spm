//
//  TerminalSelectionBounds.swift
//  libghostty-spm
//

import Foundation

/// The first and last cell of the surface's selection, in viewport
/// coordinates: what a host needs to draw selection handles over the grid.
///
/// Built from `ghostty_text_s.offset_start` and `offset_len` as
/// `ghostty_surface_read_selection` fills them. ghostty computes both from
/// the selection's top-left and bottom-right pins (Surface.zig
/// `dumpTextLocked`): `offset_start` is the top-left cell as a linear index
/// into the viewport grid (`row * columns + column`), and `offset_start +
/// offset_len` is the bottom-right cell's index the same way. Both are cell
/// counts, so a wide character's two cells and the window padding are
/// already accounted for.
///
/// A selection only partly in the viewport reports the visible part: ghostty
/// clamps a top-left above the viewport to its first cell and a bottom-right
/// below it to its last. A selection with no part visible has no bounds.
public struct TerminalSelectionBounds: Equatable, Sendable {
    public struct Cell: Equatable, Sendable {
        public let row: Int
        public let column: Int

        public init(row: Int, column: Int) {
            self.row = row
            self.column = column
        }
    }

    /// The top-left selected cell.
    public let start: Cell
    /// The bottom-right selected cell, which is itself selected.
    public let end: Cell

    public init(start: Cell, end: Cell) {
        self.start = start
        self.end = end
    }

    /// `nil` for a grid with no columns, where no offset names a cell.
    init?(offsetStart: UInt32, offsetLength: UInt32, columns: UInt16) {
        guard columns > 0 else { return nil }
        let width = Int(columns)
        let first = Int(offsetStart)
        let last = first + Int(offsetLength)
        start = Cell(row: first / width, column: first % width)
        end = Cell(row: last / width, column: last % width)
    }
}
