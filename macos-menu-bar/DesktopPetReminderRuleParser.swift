import Foundation

struct PetReminderParsedInput: Equatable {
    let title: String
    let fireDate: Date
    var recurrence: PetReminderRecurrence?

    init(title: String, fireDate: Date, recurrence: PetReminderRecurrence? = nil) {
        self.title = title
        self.fireDate = fireDate
        self.recurrence = recurrence
    }
}

enum PetReminderRuleParser {
    static func parse(
        _ input: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> PetReminderParsedInput? {
        let trimmed = clean(input)
        guard !trimmed.isEmpty else { return nil }

        if let parsed = parseRelative(trimmed, now: now, calendar: calendar) {
            return parsed
        }

        if let parsed = parseWeeklyWeekday(trimmed, now: now, calendar: calendar) {
            return parsed
        }

        if let parsed = parseRecurring(trimmed, now: now, calendar: calendar) {
            return parsed
        }

        if let parsed = parseTomorrow(trimmed, now: now, calendar: calendar) {
            return parsed
        }

        if let parsed = parseTomorrowShorthand(trimmed, now: now, calendar: calendar) {
            return parsed
        }

        if let parsed = parseToday(trimmed, now: now, calendar: calendar) {
            return parsed
        }

        return nil
    }

    private static func parseRelative(
        _ input: String,
        now: Date,
        calendar: Calendar
    ) -> PetReminderParsedInput? {
        let pattern = #"^(\d{1,4})\s*(分钟|分|小时|时|天)\s*后[\s,，]*(.+)$"#
        guard let match = firstMatch(pattern: pattern, in: input),
              let value = Int(match[1])
        else {
            return nil
        }

        let unit = match[2]
        let title = clean(match[3])
        guard !title.isEmpty else { return nil }

        let component: Calendar.Component
        switch unit {
        case "分钟", "分":
            component = .minute
        case "小时", "时":
            component = .hour
        case "天":
            component = .day
        default:
            return nil
        }

        guard let fireDate = calendar.date(byAdding: component, value: value, to: now) else {
            return nil
        }

        return PetReminderParsedInput(title: title, fireDate: fireDate)
    }

    private static func parseTomorrow(
        _ input: String,
        now: Date,
        calendar: Calendar
    ) -> PetReminderParsedInput? {
        let pattern = #"^明天\s*(上午|下午|晚上)?\s*(\d{1,2})(?:[:：点]\s*(\d{1,2})?)?[\s,，]*(.+)$"#
        guard let match = firstMatch(pattern: pattern, in: input),
              var hour = Int(match[2])
        else {
            return nil
        }

        let dayPart = match[1]
        let minute = Int(match[3]) ?? 0
        let title = clean(match[4])
        guard !title.isEmpty, (0...23).contains(hour), (0...59).contains(minute) else {
            return nil
        }

        if (dayPart == "下午" || dayPart == "晚上"), hour < 12 {
            hour += 12
        } else if dayPart == "上午", hour == 12 {
            hour = 0
        }

        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else {
            return nil
        }

        var components = calendar.dateComponents([.year, .month, .day], from: tomorrow)
        components.hour = hour
        components.minute = minute
        components.second = 0

        guard let fireDate = calendar.date(from: components) else {
            return nil
        }

        return PetReminderParsedInput(title: title, fireDate: fireDate)
    }

    /// 重复提醒：「每天 9 点 写日报」「工作日 9 点 站会」。
    private static func parseRecurring(
        _ input: String,
        now: Date,
        calendar: Calendar
    ) -> PetReminderParsedInput? {
        let pattern = #"^(每天|每日|工作日|每个工作日)\s*(上午|下午|晚上)?\s*(\d{1,2})(?:[:：点]\s*(\d{1,2})?)?[\s,，]*(.+)$"#
        guard let match = firstMatch(pattern: pattern, in: input),
              let rawHour = Int(match[3])
        else {
            return nil
        }

        let recurrence: PetReminderRecurrence
        switch match[1] {
        case "每天", "每日":
            recurrence = .daily
        case "工作日", "每个工作日":
            recurrence = .weekdays
        default:
            return nil
        }

        let hour = resolveHour(rawHour, dayPart: match[2])
        let minute = Int(match[4]) ?? 0
        let title = clean(match[5])
        guard !title.isEmpty, (0...23).contains(hour), (0...59).contains(minute) else {
            return nil
        }

        guard let fireDate = firstRecurringOccurrence(
            recurrence,
            hour: hour,
            minute: minute,
            now: now,
            calendar: calendar
        ) else {
            return nil
        }

        return PetReminderParsedInput(title: title, fireDate: fireDate, recurrence: recurrence)
    }

    /// 固定星期重复提醒：「每周一 9 点 站会」「每星期五 下午3点 复盘」。
    private static func parseWeeklyWeekday(
        _ input: String,
        now: Date,
        calendar: Calendar
    ) -> PetReminderParsedInput? {
        let pattern = #"^(?:每周|每星期|每个星期|每礼拜|每个礼拜)\s*([一二三四五六日天1-7])\s*(上午|下午|晚上)?\s*(\d{1,2})(?:[:：点]\s*(\d{1,2})?)?[\s,，]*(.+)$"#
        guard let match = firstMatch(pattern: pattern, in: input),
              let targetWeekday = weekdayNumber(from: match[1]),
              let rawHour = Int(match[3])
        else {
            return nil
        }

        let hour = resolveHour(rawHour, dayPart: match[2])
        let minute = Int(match[4]) ?? 0
        let title = clean(match[5])
        guard !title.isEmpty, (0...23).contains(hour), (0...59).contains(minute) else {
            return nil
        }

        guard let fireDate = firstWeeklyOccurrence(
            weekday: targetWeekday,
            hour: hour,
            minute: minute,
            now: now,
            calendar: calendar
        ) else {
            return nil
        }

        return PetReminderParsedInput(title: title, fireDate: fireDate, recurrence: .weekly)
    }

    /// 明早 / 明晨 / 明晚 简写：「明早 9 点 写周报」。
    private static func parseTomorrowShorthand(
        _ input: String,
        now: Date,
        calendar: Calendar
    ) -> PetReminderParsedInput? {
        let pattern = #"^(明早|明晨|明晚)\s*(\d{1,2})(?:[:：点]\s*(\d{1,2})?)?[\s,，]*(.+)$"#
        guard let match = firstMatch(pattern: pattern, in: input),
              let rawHour = Int(match[2])
        else {
            return nil
        }

        let dayPart = (match[1] == "明晚") ? "晚上" : "上午"
        let hour = resolveHour(rawHour, dayPart: dayPart)
        let minute = Int(match[3]) ?? 0
        let title = clean(match[4])
        guard !title.isEmpty, (0...23).contains(hour), (0...59).contains(minute) else {
            return nil
        }

        guard let fireDate = makeDate(dayOffset: 1, hour: hour, minute: minute, from: now, calendar: calendar) else {
            return nil
        }

        return PetReminderParsedInput(title: title, fireDate: fireDate)
    }

    /// 今天 / 今晚 / 今早 或裸时间：「下午 3 点 开会」「今晚 8 点 …」。需带「点」或「:」时间标记，避免误解析。
    /// 若该时间今天已过，则顺延到明天同一时间。
    private static func parseToday(
        _ input: String,
        now: Date,
        calendar: Calendar
    ) -> PetReminderParsedInput? {
        let pattern = #"^(今天|今晚|今早|今晨)?\s*(上午|下午|晚上)?\s*(\d{1,2})[:：点]\s*(\d{1,2})?[\s,，]*(.+)$"#
        guard let match = firstMatch(pattern: pattern, in: input),
              let rawHour = Int(match[3])
        else {
            return nil
        }

        var dayPart = match[2]
        if dayPart.isEmpty {
            switch match[1] {
            case "今晚":
                dayPart = "晚上"
            case "今早", "今晨":
                dayPart = "上午"
            default:
                dayPart = ""
            }
        }

        let hour = resolveHour(rawHour, dayPart: dayPart)
        let minute = Int(match[4]) ?? 0
        let title = clean(match[5])
        guard !title.isEmpty, (0...23).contains(hour), (0...59).contains(minute) else {
            return nil
        }

        guard let todayDate = makeDate(dayOffset: 0, hour: hour, minute: minute, from: now, calendar: calendar) else {
            return nil
        }

        if todayDate > now {
            return PetReminderParsedInput(title: title, fireDate: todayDate)
        }

        guard let tomorrowDate = makeDate(dayOffset: 1, hour: hour, minute: minute, from: now, calendar: calendar) else {
            return nil
        }
        return PetReminderParsedInput(title: title, fireDate: tomorrowDate)
    }

    private static func resolveHour(_ hour: Int, dayPart: String) -> Int {
        var resolved = hour
        if (dayPart == "下午" || dayPart == "晚上"), resolved < 12 {
            resolved += 12
        } else if dayPart == "上午", resolved == 12 {
            resolved = 0
        }
        return resolved
    }

    private static func makeDate(
        dayOffset: Int,
        hour: Int,
        minute: Int,
        from now: Date,
        calendar: Calendar
    ) -> Date? {
        guard let base = calendar.date(byAdding: .day, value: dayOffset, to: now) else { return nil }
        var components = calendar.dateComponents([.year, .month, .day], from: base)
        components.hour = hour
        components.minute = minute
        components.second = 0
        return calendar.date(from: components)
    }

    private static func firstRecurringOccurrence(
        _ recurrence: PetReminderRecurrence,
        hour: Int,
        minute: Int,
        now: Date,
        calendar: Calendar
    ) -> Date? {
        guard let todayAt = makeDate(dayOffset: 0, hour: hour, minute: minute, from: now, calendar: calendar) else {
            return nil
        }
        var candidate = todayAt
        if candidate <= now {
            candidate = recurrence.nextOccurrence(after: candidate, reference: now, calendar: calendar)
        }
        if recurrence.frequency == .weekdays {
            var guardCount = 0
            while PetReminderRecurrence.isWeekend(candidate, calendar: calendar) && guardCount < 14 {
                guard let next = calendar.date(byAdding: .day, value: 1, to: candidate) else { break }
                candidate = next
                guardCount += 1
            }
        }
        return candidate
    }

    private static func firstWeeklyOccurrence(
        weekday targetWeekday: Int,
        hour: Int,
        minute: Int,
        now: Date,
        calendar: Calendar
    ) -> Date? {
        let currentWeekday = calendar.component(.weekday, from: now)
        let dayOffset = (targetWeekday - currentWeekday + 7) % 7
        guard let candidate = makeDate(dayOffset: dayOffset, hour: hour, minute: minute, from: now, calendar: calendar) else {
            return nil
        }

        if candidate > now {
            return candidate
        }
        return calendar.date(byAdding: .day, value: 7, to: candidate)
    }

    private static func weekdayNumber(from value: String) -> Int? {
        switch value {
        case "日", "天", "7":
            return 1
        case "一", "1":
            return 2
        case "二", "2":
            return 3
        case "三", "3":
            return 4
        case "四", "4":
            return 5
        case "五", "5":
            return 6
        case "六", "6":
            return 7
        default:
            return nil
        }
    }

    private static func firstMatch(pattern: String, in input: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(input.startIndex..<input.endIndex, in: input)
        guard let match = regex.firstMatch(in: input, range: nsRange) else { return nil }

        return (0..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: input) else {
                return ""
            }
            return String(input[swiftRange])
        }
    }

    private static func clean(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "，,。:：- "))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
