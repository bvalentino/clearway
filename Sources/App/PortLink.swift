import Foundation

/// The text a live port renders as, and the URL it opens.
///
/// Every string here is built with `String(port)` rather than interpolated into a literal, and
/// every call site passes the result as a `String` expression. A `UInt16` interpolated into a
/// string *literal* handed to `Text` or `.help` binds the `LocalizedStringKey` overload, which
/// formats integers for the locale: `.help("http://localhost:\(port)")` rendered
/// `http://localhost:3,000`.
enum PortLink {
    static func label(_ port: UInt16) -> String {
        String(port)
    }

    static func urlString(_ port: UInt16) -> String {
        "http://localhost:" + String(port)
    }

    static func url(_ port: UInt16) -> URL? {
        URL(string: urlString(port))
    }
}
