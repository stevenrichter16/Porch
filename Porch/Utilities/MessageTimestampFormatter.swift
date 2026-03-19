import Foundation

/// Utility for formatting message timestamps.
///
/// The formatter chooses a short time‑only format when the date is on the
/// same day as the reference date, otherwise it shows month and day.
struct MessageTimestampFormatter {
    /// Returns a localized string representation of *date* relative to
    /// *referenceDate*.
    ///
    /// - Parameters:
    ///   - date: The date to format.
    ///   - referenceDate: The date that the result is compared against.  By
    ///     default this is ``Date.now``.
    ///   - calendar: Calendar used for the same‑day comparison.  Defaults to
    ///     ``Calendar.autoupdatingCurrent``.
    ///   - locale: Locale used for the formatter.  Defaults to
    ///     ``Locale.autoupdatingCurrent``.
    ///   - timeZone: Time‑zone used for the formatter.  Defaults to
    ///     ``TimeZone.autoupdatingCurrent``.
    /// - Returns: A localized string such as "3 pm" or "Mar 2 3 pm".
    static func string(
        for date: Date,
        relativeTo referenceDate: Date = .now,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        let formatTemplate = calendar.isDate(date, inSameDayAs: referenceDate) ? "jm" : "MMM d jm"
        return formattedString(from: date, template: formatTemplate, locale: locale, timeZone: timeZone)
    }

    /// Helper that creates a ``DateFormatter`` for the given template.
    private static func formattedString(from date: Date,
                                        template: String,
                                        locale: Locale,
                                        timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}
