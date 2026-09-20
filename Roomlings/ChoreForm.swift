import RoomlingsCore
import SwiftUI

struct ChoreFormValues {
    var title = ""
    var notes = ""
    var roomID = "kitchen"
    var area = ""
    var componentID = ""
    var dueDate = Date.now
    var repeatChoice = ""
    var customDays = "3"
    var rotation: [UUID] = []
    var nextMemberID: UUID?
}

struct ChoreForm: View {
    @Binding var values: ChoreFormValues
    let chores: HouseholdChores
    let catalog: ChoreCatalog
    let objects: [ChoreObject]
    let calendar: ChoreCalendar
    let disabled: Bool
    let onSubmit: (ChoreDraft) -> Void
    @State private var error: String?

    private var room: ChoreCatalog.Room? { catalog.rooms.first { $0.id == values.roomID } }
    private var availableObjects: [ChoreObject] {
        objects.filter {
            $0.installed && $0.roomID == values.roomID && (values.area.isEmpty || $0.area == values.area)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Choose a room, schedule and who takes turns.")
                .foregroundStyle(RoomTheme.muted)
            RoomField("Chore name", text: $values.title)
                .accessibilityIdentifier("chore-name-field")
            locationFields
            RoomField("Notes", text: $values.notes, axis: .vertical)
                .lineLimit(2...5)
            DatePicker("Due date", selection: Binding(
                get: { calendar.pickerDate(values.dueDate) },
                set: { values.dueDate = calendar.instant(fromPickerDate: $0) }
            ), in: calendar.minimumDate..., displayedComponents: .date)
                .environment(\.calendar, calendar.calendar)
                .environment(\.timeZone, calendar.timeZone)
                .accessibilityIdentifier("chore-due-date")
            RoomPickerField("Repeat", selectedLabel: repeatLabel, selection: $values.repeatChoice) {
                Text("One-off").tag("")
                Text("Daily").tag("1")
                Text("Weekly").tag("7")
                Text("Every 2 weeks").tag("14")
                Text("Custom interval").tag("custom")
            }
            if values.repeatChoice == "custom" {
                RoomField("Repeat every (days)", text: $values.customDays)
                    .keyboardType(.numberPad)
            }
            rotationFields
            Text("One person keeps the assignment. Multiple people rotate in the order above after each completion. Dates use \(calendar.identifier).")
                .font(RoomTheme.body(14))
                .foregroundStyle(RoomTheme.muted)
            if let error {
                RoomFeedback(error, identifier: "chore-form-error")
            }
            Button("Create chore", action: submit)
                .buttonStyle(RoomButtonStyle(kind: .primary))
                .disabled(values.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || values.rotation.isEmpty)
        }
        .disabled(disabled)
    }

    private var locationFields: some View {
        VStack(alignment: .leading, spacing: 20) {
            RoomPickerField("Room", selectedLabel: catalog.location(roomID: values.roomID.isEmpty ? nil : values.roomID, area: nil),
                        selection: Binding(get: { values.roomID }, set: {
                values.roomID = $0
                values.area = ""
                values.componentID = ""
            })) {
                Text("Whole home").tag("")
                ForEach(catalog.rooms) { room in Text(room.name).tag(room.id) }
            }
            if let room {
                RoomPickerField("Area", selectedLabel: values.area.isEmpty ? "Whole room"
                            : room.areas.first(where: { $0.id == values.area })?.label ?? "Unavailable area",
                            selection: Binding(get: { values.area }, set: {
                    values.area = $0
                    values.componentID = ""
                })) {
                    Text("Whole room").tag("")
                    ForEach(room.areas) { area in Text(area.label).tag(area.id) }
                }
                RoomPickerField("Room object", selectedLabel: values.componentID.isEmpty ? "No object"
                            : availableObjects.first(where: { $0.id == values.componentID })?.displayName(in: availableObjects) ?? "Object unavailable",
                            selection: Binding(get: { values.componentID }, set: { id in
                    values.componentID = id
                    if let object = objects.first(where: { $0.id == id }) { values.area = object.area ?? "" }
                })) {
                    Text("No object").tag("")
                    if !values.componentID.isEmpty && !availableObjects.contains(where: { $0.id == values.componentID }) {
                        Text("Object unavailable").tag(values.componentID)
                    }
                    ForEach(availableObjects) { object in Text(object.displayName(in: availableObjects)).tag(object.id) }
                }
            }
        }
    }

    private var rotationFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Who takes turns?").font(RoomTheme.heading(20))
            ForEach(chores.members.filter { !$0.inactive || values.rotation.contains($0.id) }) { member in
                RoomSwitch(member.name + (member.inactive ? " (former roommate)" : ""),
                       isOn: Binding(get: { values.rotation.contains(member.id) }, set: { selected in
                    if selected {
                        values.rotation.append(member.id)
                    } else {
                        values.rotation.removeAll { $0 == member.id }
                    }
                    if !values.rotation.contains(where: { $0 == values.nextMemberID }) {
                        values.nextMemberID = values.rotation.first
                    }
                }))
                .frame(minHeight: 44)
            }
            if values.rotation.count > 1 {
                VStack(spacing: 4) {
                    ForEach(Array(values.rotation.enumerated()), id: \.element) { index, id in
                        let name = memberName(id)
                        HStack {
                            Text("\(index + 1). \(name)")
                            Spacer()
                            Button { moveMember(at: index, by: -1) } label: {
                                Image(systemName: "arrow.up").frame(minWidth: 44, minHeight: 44)
                            }
                            .accessibilityLabel("Move \(name) earlier")
                            .disabled(index == 0)
                            Button { moveMember(at: index, by: 1) } label: {
                                Image(systemName: "arrow.down").frame(minWidth: 44, minHeight: 44)
                            }
                            .accessibilityLabel("Move \(name) later")
                            .disabled(index == values.rotation.count - 1)
                        }
                        .buttonStyle(RoomButtonStyle(kind: .text))
                    }
                }
                .accessibilityIdentifier("chore-rotation")
            }
            RoomPickerField("Next turn", selectedLabel: values.nextMemberID.map(memberName) ?? "Choose a roommate",
                        selection: $values.nextMemberID) {
                if values.rotation.isEmpty { Text("Choose a roommate").tag(Optional<UUID>.none) }
                ForEach(values.rotation, id: \.self) { id in Text(memberName(id)).tag(Optional(id)) }
            }
            .disabled(values.rotation.isEmpty)
        }
    }

    private func memberName(_ id: UUID) -> String {
        chores.members.first(where: { $0.id == id })?.name ?? "Former roommate"
    }

    private var repeatLabel: String {
        ["": "One-off", "1": "Daily", "7": "Weekly", "14": "Every 2 weeks", "custom": "Custom interval"][values.repeatChoice]
            ?? "Choose a repeat interval"
    }

    private func moveMember(at index: Int, by direction: Int) {
        guard values.rotation.indices.contains(index), values.rotation.indices.contains(index + direction) else {
            error = "Review the rotation order before changing it."
            return
        }
        values.rotation.swapAt(index, index + direction)
    }

    private func submit() {
        guard let next = values.nextMemberID, let turn = values.rotation.firstIndex(of: next),
              values.rotation.allSatisfy({ id in chores.members.contains { $0.id == id && !$0.inactive } }) else {
            error = "Choose active roommates and a next turn from this rotation."
            return
        }
        let repeatDays: Int?
        if values.repeatChoice.isEmpty {
            repeatDays = nil
        } else {
            guard let days = Int(values.repeatChoice == "custom" ? values.customDays : values.repeatChoice),
                  (1...365).contains(days) else {
                error = "Choose a repeat interval from 1 to 365 days."
                return
            }
            repeatDays = days
        }
        if !values.componentID.isEmpty && !availableObjects.contains(where: { $0.id == values.componentID }) {
            error = "Choose an installed object here, or choose No object."
            return
        }
        do {
            let draft = try ChoreDraft(
                title: values.title, notes: values.notes,
                roomID: values.roomID.isEmpty ? nil : values.roomID,
                area: values.area.isEmpty ? nil : values.area,
                componentID: values.componentID.isEmpty ? nil : values.componentID,
                dueDate: calendar.day(values.dueDate), repeatDays: repeatDays,
                rotation: values.rotation, turn: turn
            )
            error = nil
            onSubmit(draft)
        } catch {
            self.error = "Use a name of 1 to 80 characters, notes of up to 240 characters, a valid date and at most 12 active roommates."
        }
    }
}
