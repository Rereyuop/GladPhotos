import SwiftUI

struct CalendarFilterView: View {
    @Binding var selectedMonthDate: Date
    let dateIndex: MediaDateIndex
    @Binding var activeDay: Date?
    @Binding var pendingScrollTarget: Date?

    let onMonthSelected: (Date) -> Void
    let onToday: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = .gladPhotosChinese
        calendar.firstWeekday = 2
        return calendar
    }
    private let monthColumns = Array(
        repeating: GridItem(.flexible(), spacing: 8),
        count: 3
    )
    private let dayColumns = Array(
        repeating: GridItem(.flexible(), spacing: 4),
        count: 7
    )

    private var selectedYear: Int {
        calendar.component(.year, from: selectedMonthDate)
    }

    private var selectedMonth: Int {
        calendar.component(.month, from: selectedMonthDate)
    }

    private var years: [Int] {
        dateIndex.years
    }

    private var availableMonths: [Int] {
        dateIndex.months(in: selectedYear)
    }

    private var availableDays: Set<Date> {
        dateIndex.days(in: selectedMonthDate, calendar: calendar)
    }

    private var selectionAnimation: Animation? {
        reduceMotion ? nil : .snappy(duration: 0.2)
    }

    private var calendarDates: [Date] {
        guard
            let monthStart = calendar.date(
                from: calendar.dateComponents(
                    [.year, .month],
                    from: selectedMonthDate
                )
            ),
            let dayRange = calendar.range(of: .day, in: .month, for: monthStart)
        else {
            return []
        }

        let weekday = calendar.component(.weekday, from: monthStart)
        let leadingDays = (weekday - calendar.firstWeekday + 7) % 7
        let visibleDayCount = leadingDays + dayRange.count
        let cellCount = Int(ceil(Double(visibleDayCount) / 7.0)) * 7

        guard let gridStart = calendar.date(
            byAdding: .day,
            value: -leadingDays,
            to: monthStart
        ) else {
            return []
        }

        return (0..<cellCount).compactMap {
            calendar.date(byAdding: .day, value: $0, to: gridStart)
        }
    }

    private var weekdays: [CalendarWeekday] {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = .gladPhotosChinese
        let symbols = formatter.veryShortStandaloneWeekdaySymbols ?? []

        return (0..<7).compactMap { offset in
            let weekday = ((calendar.firstWeekday - 1 + offset) % 7) + 1
            let symbolIndex = weekday - 1

            guard symbols.indices.contains(symbolIndex) else {
                return nil
            }

            return CalendarWeekday(id: weekday, title: symbols[symbolIndex])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("日期")
                    .font(.headline)

                Spacer()

                Button("今天") {
                    onToday()
                }
                .buttonStyle(CalendarHoverButtonStyle(isSelected: false))
                .pointingHandCursor()
            }

            yearSelector

            LazyVGrid(columns: monthColumns, spacing: 8) {
                ForEach(availableMonths, id: \.self) { month in
                    monthButton(month)
                }
            }
            .animation(selectionAnimation, value: selectedMonthDate)

            Divider()

            monthCalendar
        }
    }

    private var yearSelector: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    ForEach(years, id: \.self) { year in
                        yearButton(year) {
                            let months = dateIndex.months(in: year)
                            let month = months.contains(selectedMonth)
                                ? selectedMonth
                                : (months.last ?? selectedMonth)
                            updateDate(year: year, month: month)
                        }
                        .id(year)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .onAppear {
                Task { @MainActor in
                    scrollToYear(selectedYear, proxy: proxy, animated: false)
                }
            }
            .onChange(of: selectedYear) { _, newYear in
                scrollToYear(newYear, proxy: proxy, animated: true)
            }
            .animation(selectionAnimation, value: selectedMonthDate)
        }
        .frame(height: 34)
    }

    private var monthCalendar: some View {
        LazyVGrid(columns: dayColumns, spacing: 4) {
            ForEach(weekdays) { weekday in
                Text(weekday.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }

            ForEach(calendarDates, id: \.self) { date in
                dayButton(date)
            }
        }
        .animation(selectionAnimation, value: activeDay)
        .frame(height: 220, alignment: .top)
    }

    @ViewBuilder
    private func yearButton(
        _ year: Int,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(String(year))
                .contentTransition(.numericText())
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
        }
        .buttonStyle(CalendarHoverButtonStyle(isSelected: year == selectedYear))
        .pointingHandCursor()
    }

    @ViewBuilder
    private func monthButton(_ month: Int) -> some View {
        Button {
            updateDate(year: selectedYear, month: month)
        } label: {
            Text(monthName(month))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
        }
        .buttonStyle(CalendarHoverButtonStyle(isSelected: month == selectedMonth))
        .pointingHandCursor()
    }

    private func updateDate(year: Int, month: Int) {
        let currentDay = calendar.component(.day, from: selectedMonthDate)

        guard
            let firstDayOfTargetMonth = calendar.date(
                from: DateComponents(year: year, month: month, day: 1)
            ),
            let dayRange = calendar.range(
                of: .day,
                in: .month,
                for: firstDayOfTargetMonth
            ),
            let newDate = calendar.date(
                from: DateComponents(
                    year: year,
                    month: month,
                    day: min(currentDay, dayRange.count)
                )
            )
        else {
            return
        }

        selectedMonthDate = newDate
        activeDay = nil
        pendingScrollTarget = nil
        onMonthSelected(newDate)
    }

    private func dayButton(_ date: Date) -> some View {
        let day = calendar.startOfDay(for: date)
        let isCurrentMonth = calendar.isDate(
            date,
            equalTo: selectedMonthDate,
            toGranularity: .month
        )
        let isAvailable = isCurrentMonth && availableDays.contains(day)
        let isActive = activeDay == day

        return Button {
            guard isAvailable else {
                return
            }

            activeDay = day
            pendingScrollTarget = day
        } label: {
            ZStack {
                if isActive {
                    Circle()
                        .fill(.tint)
                        .frame(width: 24, height: 24)
                }

                Text(String(calendar.component(.day, from: date)))
                    .foregroundStyle(
                        isActive
                            ? AnyShapeStyle(Color.white)
                            : AnyShapeStyle(isCurrentMonth ? .primary : .quaternary)
                    )
                    .fontWeight(isActive ? .semibold : .regular)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .overlay(alignment: .bottom) {
                if isAvailable && !isActive {
                    Circle()
                        .fill(.tint)
                        .frame(width: 4, height: 4)
                        .offset(y: -1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(CalendarHoverButtonStyle(isSelected: isActive, cornerRadius: 5))
        .disabled(!isAvailable)
        .pointingHandCursor()
    }

    private func scrollToYear(
        _ year: Int,
        proxy: ScrollViewProxy,
        animated: Bool
    ) {
        let animation: Animation? = animated && !reduceMotion
            ? .snappy(duration: 0.25)
            : nil

        withAnimation(animation) {
            proxy.scrollTo(year, anchor: .leading)
        }
    }

    private func monthName(_ month: Int) -> String {
        "\(month) 月"
    }
}

#Preview {
    CalendarFilterView(
        selectedMonthDate: .constant(Date()),
        dateIndex: .empty,
        activeDay: .constant(nil),
        pendingScrollTarget: .constant(nil),
        onMonthSelected: { _ in },
        onToday: {}
    )
}

private struct CalendarWeekday: Identifiable {
    let id: Int
    let title: String
}

private struct CalendarHoverButtonStyle: ButtonStyle {
    let isSelected: Bool
    var cornerRadius: CGFloat = 6

    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(
                        isHovering || configuration.isPressed
                            ? Color.primary.opacity(0.09)
                            : Color.clear
                    )
            }
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
    }
}
