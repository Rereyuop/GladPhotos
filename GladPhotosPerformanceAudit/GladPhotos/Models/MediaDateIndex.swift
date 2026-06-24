import Foundation

struct MediaMonth: Hashable {
    let year: Int
    let month: Int

    init(_ date: Date, calendar: Calendar = .current) {
        year = calendar.component(.year, from: date)
        month = calendar.component(.month, from: date)
    }
}

struct MediaDateIndex: Equatable {
    static let empty = MediaDateIndex(dates: [])

    let years: [Int]
    let monthsByYear: [Int: [Int]]
    let daysByMonth: [MediaMonth: Set<Date>]
    let latestDate: Date?

    init<S: Sequence>(dates: S, calendar: Calendar = .current) where S.Element == Date {
        var daysByMonth: [MediaMonth: Set<Date>] = [:]
        var monthsByYear: [Int: Set<Int>] = [:]
        var latestDate: Date?

        for date in dates {
            let month = MediaMonth(date, calendar: calendar)
            daysByMonth[month, default: []].insert(calendar.startOfDay(for: date))
            monthsByYear[month.year, default: []].insert(month.month)
            if latestDate == nil || date > latestDate! {
                latestDate = date
            }
        }

        self.years = monthsByYear.keys.sorted(by: >)
        self.monthsByYear = monthsByYear.mapValues { $0.sorted() }
        self.daysByMonth = daysByMonth
        self.latestDate = latestDate
    }

    func months(in year: Int) -> [Int] {
        monthsByYear[year] ?? []
    }

    func days(in date: Date, calendar: Calendar = .current) -> Set<Date> {
        daysByMonth[MediaMonth(date, calendar: calendar)] ?? []
    }

    func containsMonth(_ date: Date, calendar: Calendar = .current) -> Bool {
        daysByMonth[MediaMonth(date, calendar: calendar)] != nil
    }
}
