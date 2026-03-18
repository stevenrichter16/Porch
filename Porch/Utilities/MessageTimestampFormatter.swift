import Foundation

enum MessageTimestampFormatter {
    static func string(
        for date: Date,
        relativeTo referenceDate: Date = .now,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone

        if calendar.isDate(date, inSameDayAs: referenceDate) {
            formatter.setLocalizedDateFormatFromTemplate("jm")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("MMM d jm")
        }

        return formatter.string(from: date)
    }
}
