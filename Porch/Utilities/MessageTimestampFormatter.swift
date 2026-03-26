import Foundation

enum MessageTimestampFormatter {
    static func string(
        for date: Date,
        relativeTo referenceDate: Date = .now,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        let formatter = makeFormatter(locale: locale, timeZone: timeZone)

        if calendar.isDate(date, inSameDayAs: referenceDate) {
            formatter.setLocalizedDateFormatFromTemplate("jm")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("MMM d jm")
        }

        return formatter.string(from: date)
    }

    private static func makeFormatter(locale: Locale, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        return formatter
    }
}
