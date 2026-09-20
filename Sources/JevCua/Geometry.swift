import Foundation
import CoreGraphics

/// The four coordinate spaces jev deals in, made into types so mixing them
/// stops compiling.
///
/// They were all `Double` before, and on one non-Retina display several of
/// them are numerically identical — which is precisely why the mistakes stayed
/// invisible. Two shipped:
///
///   * a click was addressed in **points** where the driver wanted **pixels**,
///     so every tap from the phone landed a quarter of the way in;
///   * controls on a second display were normalised against the first, giving
///     negative coordinates, and their badges were drawn off the top of the
///     picture where nothing could clip them into view.
///
/// Neither was a hard bug to see once measured. Both were impossible to see
/// by reading, because `Double * Double` says nothing about what it means.
public enum Geometry {

    /// The display the phone is being shown. Everything is relative to this
    /// one; another monitor is a different screen and is refused, not guessed.
    public struct Shown: Sendable, Equatable {
        /// Width and height in points, as the driver reports them.
        public let width: Double
        public let height: Double
        /// Points x scale = pixels. 2 on a Retina Mac.
        public let scale: Double

        public init(width: Double, height: Double, scale: Double) {
            self.width = width
            self.height = height
            // Clamping a bogus scale to 1 is the factor-of-two bug wearing a
            // different hat: 0 or NaN from the driver would silently halve
            // every coordinate. A caller that cannot supply a real scale
            // should refuse, and `isUsable` is how it finds out.
            self.scale = (scale.isFinite && scale >= 1) ? scale : .nan
        }

        public var bounds: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }
        public var isUsable: Bool {
            // `isFinite` on the size too, not only the scale. `width > 0`
            // is true of infinity, and `0 * .infinity` is NaN — the one
            // value that must never reach a JSON request, because the
            // exception it raises cannot be caught.
            width.isFinite && height.isFinite && width > 0 && height > 0
                && scale.isFinite && scale >= 1
        }
    }

    // MARK: - Points

    /// A position on the shown display, in points — the space the driver
    /// reports element frames and window bounds in.
    public struct Points: Sendable, Equatable {
        public let x: Double
        public let y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }

    /// A position in the space a click is addressed in.
    ///
    /// The only way to make one is to convert from points, because writing a
    /// literal here is the mistake this type exists to prevent.
    public struct Pixels: Sendable, Equatable {
        public let x: Double
        public let y: Double
        fileprivate init(x: Double, y: Double) { self.x = x; self.y = y }
    }

    /// A position as a fraction of the shown display, 0…1. The only space
    /// that crosses the wire, because the phone knows nothing about Mac
    /// pixels and must never be told.
    public struct Normalised: Sendable, Equatable {
        public let x: Double
        public let y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }

        /// Inside the picture, and therefore pressable.
        public var isOnScreen: Bool { (0...1).contains(x) && (0...1).contains(y) }
    }

    // MARK: - The only legal conversions

    /// Points to the pixels a click is addressed in.
    ///
    /// Optional for the same reason the other conversions are: an unusable
    /// `Shown` carries a NaN scale, and NaN in a JSON object raises an
    /// Objective-C exception that Swift CANNOT catch — the daemon simply
    /// dies. Returning nil makes the compiler ask the question at every call
    /// site, which is the only way to be sure it is asked.
    public static func pixels(_ point: Points, on shown: Shown) -> Pixels? {
        guard shown.isUsable, point.x.isFinite, point.y.isFinite else { return nil }
        return Pixels(x: point.x * shown.scale, y: point.y * shown.scale)
    }

    /// A fraction of the display to the pixels a click is addressed in.
    ///
    /// Two multiplications, in one place. Doing it by hand is how the factor
    /// of two went missing.
    public static func pixels(_ point: Normalised, on shown: Shown) -> Pixels? {
        guard shown.isUsable, point.x.isFinite, point.y.isFinite else { return nil }
        let clamped = Normalised(x: min(1, max(0, point.x)), y: min(1, max(0, point.y)))
        return Pixels(x: clamped.x * shown.width * shown.scale,
                      y: clamped.y * shown.height * shown.scale)
    }

    /// Points to a fraction of the display, for sending to the phone.
    public static func normalised(_ point: Points, on shown: Shown) -> Normalised? {
        guard shown.isUsable, point.x.isFinite, point.y.isFinite else { return nil }
        return Normalised(x: point.x / shown.width, y: point.y / shown.height)
    }

    /// A rectangle in points to one in fractions, for sending to the phone.
    ///
    /// Nil when the rectangle is not on this display at all — which is the
    /// honest answer for a window on the second monitor, and better than the
    /// negative coordinates that produced invisible badges.
    public static func normalised(_ rect: CGRect, on shown: Shown) -> (x: Double, y: Double, w: Double, h: Double)? {
        guard shown.isUsable, rect.width > 0, rect.height > 0 else { return nil }
        // The CENTRE decides, because that is where a badge is drawn.
        //
        // Full containment was wrong in the other direction: a toolbar button
        // at x=1750 w=80 on an 1800-wide display is plainly visible, but its
        // right edge is past the end, so it lost its number and the user was
        // told there was nothing pressable. Anything a person can see and
        // point at gets a number.
        let box = rect.standardized
        guard isCentredOnShownDisplay(box, shown) else { return nil }

        // Return the part you can SEE, by intersecting with the display.
        //
        // Clamping the origin on its own was not enough: a box at x = -20
        // with width 80 clamped to x = 0 but kept its full width, so the
        // badge drawn at its centre sat 10 points to the right of where the
        // visible half actually is. The intersection is correct on all four
        // edges by construction rather than by three separate min/max.
        let visible = box.intersection(shown.bounds)
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return nil }
        return (x: visible.minX / shown.width,
                y: visible.minY / shown.height,
                w: visible.width / shown.width,
                h: visible.height / shown.height)
    }

    // MARK: - Identity

    /// Is this rectangle on the display the phone is being shown?
    ///
    /// Fully, not fractionally. Testing for any intersection was not enough:
    /// a window at x = 1799 on the second display clips an 1800-wide main
    /// display by a single pixel, passed that test, and kept winning on
    /// z-order — so jev went on acting in a window nobody could see.
    public static func isOnShownDisplay(_ rect: CGRect, _ shown: Shown) -> Bool {
        guard shown.isUsable else { return false }
        let slack = 1.0
        return rect.minX >= -slack && rect.minY >= -slack
            && rect.maxX <= shown.width + slack
            && rect.maxY <= shown.height + slack
    }

    /// Is this window's *centre* on the shown display?
    ///
    /// The looser test, for choosing which window to act in: a window may
    /// legitimately hang off an edge, but the one you are looking at is the
    /// one whose middle is on the screen you are looking at.
    public static func isCentredOnShownDisplay(_ rect: CGRect, _ shown: Shown) -> Bool {
        // A zero-size window is not somewhere you can be looking. Letting one
        // through made it a candidate for selection, and a target with no
        // size then silently disabled the scroll aim.
        guard shown.isUsable, rect.width > 0, rect.height > 0 else { return false }
        let box = rect.standardized
        return shown.bounds.contains(CGPoint(x: box.midX, y: box.midY))
    }
}
