//
//  BoringCalendar.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 08/09/24.
//

import Defaults
import SwiftUI

struct CalendarView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject private var calendarManager = CalendarManager.shared
    @ObservedObject private var musicManager = MusicManager.shared
    @Default(.playerColorTinting) private var playerColorTinting
    @State private var selectedDate = Date()
    @State private var calendarWidth: CGFloat = 155

    private let cal = Calendar.current
    private let dayHeaders = ["M", "T", "W", "T", "F", "S", "S"]

    // macOS Calendar red — fallback when tinting is off or player is idle
    private static let fallbackRed = Color(red: 1.0, green: 0.231, blue: 0.188)

    private var calendarAccent: Color {
        guard playerColorTinting else { return Self.fallbackRed }
        return .playerTint(from: musicManager.avgColor, fallback: Self.fallbackRed)
    }

    // Text color that contrasts against the calendarAccent circle fill
    private var todayTextColor: Color {
        guard playerColorTinting,
              let luminance = musicManager.avgColor.srgbLuminance,
              luminance < 0.9 else { return .white }
        return luminance > 0.5 ? .black : .white
    }

    private var displayMonth: Date {
        cal.date(from: cal.dateComponents([.year, .month], from: selectedDate)) ?? selectedDate
    }

    private var flatDays: [Date?] {
        guard let startOfMonth = cal.date(from: cal.dateComponents([.year, .month], from: displayMonth)),
              let dayRange = cal.range(of: .day, in: .month, for: startOfMonth) else { return [] }
        let dayCount = dayRange.count
        // weekday: 1=Sun, 2=Mon … convert to Monday-first column offset
        let weekday = cal.component(.weekday, from: startOfMonth)
        let offset = (weekday - 2 + 7) % 7

        var days: [Date?] = Array(repeating: nil, count: offset)
        for i in 0..<dayCount {
            days.append(cal.date(byAdding: .day, value: i, to: startOfMonth))
        }
        while days.count % 7 != 0 { days.append(nil) }
        return days
    }

    var body: some View {
        VStack(spacing: 4) {
            // Month name offset to align its first character with the "M" of Monday.
            // Each column = calendarWidth/7; "M" is centered in column 0, so its left
            // edge sits at calendarWidth/14 minus ~half the glyph width (~4pt).
            Text(displayMonth.formatted(.dateTime.month(.wide)).uppercased())
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(calendarAccent)
                .padding(.leading, max(0, calendarWidth / 14 - 4))
                .frame(maxWidth: .infinity, alignment: .leading)

            // Day-of-week headers: centered in each column to match the date numbers below
            HStack(spacing: 0) {
                ForEach(dayHeaders.indices, id: \.self) { i in
                    Text(dayHeaders[i])
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundColor(i >= 5 ? Color(white: 0.4) : Color(white: 0.7))
                        .frame(maxWidth: .infinity)
                }
            }

            // Date grid
            let days = flatDays
            let rowCount = days.count / 7
            VStack(spacing: 2) {
                ForEach(0..<rowCount, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { col in
                            let idx = row * 7 + col
                            if let date = days[idx] {
                                dateCell(date: date, column: col)
                            } else {
                                Color.clear.frame(maxWidth: .infinity, minHeight: 16)
                            }
                        }
                    }
                }
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear.onAppear { calendarWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in calendarWidth = w }
            }
        )
        .onChange(of: selectedDate) {
            Task { await calendarManager.updateCurrentDate(selectedDate) }
        }
        .onChange(of: vm.notchState) { _, _ in
            Task {
                await calendarManager.updateCurrentDate(Date.now)
                selectedDate = Date.now
            }
        }
        .onAppear {
            Task {
                await calendarManager.updateCurrentDate(Date.now)
                selectedDate = Date.now
            }
        }
    }

    private func dateCell(date: Date, column: Int) -> some View {
        let isToday = cal.isDateInToday(date)
        let isWeekend = column >= 5

        return Button(action: {
            if let url = URL(string: "calshow://\(date.timeIntervalSinceReferenceDate)") {
                NSWorkspace.shared.open(url)
            }
        }) {
            ZStack {
                if isToday {
                    Circle()
                        .fill(calendarAccent)
                        .frame(width: 18, height: 18)
                }
                Text("\(cal.component(.day, from: date))")
                    .font(.caption2)
                    .fontWeight(isToday ? .semibold : .regular)
                    .foregroundColor(
                        isToday ? todayTextColor :
                        isWeekend ? Color(white: 0.4) :
                        Color(white: 0.9)
                    )
            }
            .frame(maxWidth: .infinity, minHeight: 16)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

#Preview {
    CalendarView()
        .frame(width: 155)
        .padding()
        .background(.black)
        .environmentObject(BoringViewModel())
}
