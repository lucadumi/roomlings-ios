import SwiftUI
import UIKit

enum RoomControlAppearance: Sendable {
    case system, roomlings

    // Set this to .system to turn off the styling trial.
    static let defaultAppearance = Self.roomlings

    static var current: Self {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-roomlings-system-controls") { return .system }
        if ProcessInfo.processInfo.arguments.contains("-roomlings-custom-controls") { return .roomlings }
        #endif
        return defaultAppearance
    }

    #if DEBUG
    // A local interaction fixture for simulator tests, with no account, API or room renderer.
    struct RoomControlStyleFixture: View {
        @State private var presented = true
        @State private var room = "Kitchen"
        @State private var mine = false
        @State private var section = "Chores"
        @State private var enabled = true

        var body: some View {
            RoomTheme.paper.ignoresSafeArea()
                .sheet(isPresented: $presented) {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("Control styling").font(RoomTheme.heading())
                        Group {
                            RoomPickerField("Room", selectedLabel: room, selection: $room) {
                                Text("Kitchen").tag("Kitchen")
                                Text("Bathroom").tag("Bathroom")
                            }
                            RoomSwitch("My turn only", isOn: $mine)
                            RoomSegmentedPicker("Chore sections", selection: $section, options: ["Chores", "History", "Archived"]) { $0 }
                                .accessibilityIdentifier("fixture-segments")
                        }
                        .disabled(!enabled)
                        RoomSwitch("Enable controls", isOn: $enabled)
                        Text("\(room)|\(mine ? "on" : "off")|\(section)")
                            .accessibilityIdentifier("fixture-selection")
                    }
                    .padding(24)
                    .font(RoomTheme.body())
                    .foregroundStyle(RoomTheme.ink)
                    .tint(RoomTheme.sage)
                    .presentationBackground(RoomTheme.paper)
                    .presentationCornerRadius(16)
                    .modifier(RoomSheetPresentation(idealHeight: 420))
                    .interactiveDismissDisabled()
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("control-fixture")
                }
        }
    }
    #endif
}

struct RoomPickerField<Selection: Hashable, Options: View>: View {
    let label: String
    let selectedLabel: String
    @Binding var selection: Selection
    let options: Options

    init(_ label: String, selectedLabel: String, selection: Binding<Selection>, @ViewBuilder options: () -> Options) {
        self.label = label
        self.selectedLabel = selectedLabel
        _selection = selection
        self.options = options()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(RoomTheme.body(14)).foregroundStyle(RoomTheme.muted)
            RoomMenuPicker(label, selectedLabel: selectedLabel, selection: $selection) { options }
        }
    }
}

private struct RoomControlAppearanceKey: EnvironmentKey {
    static let defaultValue = RoomControlAppearance.system
}

extension EnvironmentValues {
    var roomControlAppearance: RoomControlAppearance {
        get { self[RoomControlAppearanceKey.self] }
        set { self[RoomControlAppearanceKey.self] = newValue }
    }
}

struct RoomMenuPicker<Selection: Hashable, Options: View>: View {
    @Environment(\.roomControlAppearance) private var appearance
    @Environment(\.isEnabled) private var enabled
    let label: String
    let selectedLabel: String
    @Binding var selection: Selection
    let options: Options

    init(_ label: String, selectedLabel: String, selection: Binding<Selection>, @ViewBuilder options: () -> Options) {
        self.label = label
        self.selectedLabel = selectedLabel
        _selection = selection
        self.options = options()
    }

    var body: some View {
        if appearance == .roomlings {
            Menu {
                Picker(label, selection: $selection) { options }
                    .pickerStyle(.inline)
                    .labelsHidden()
            } label: {
                HStack(spacing: 12) {
                    Text(selectedLabel)
                        .foregroundStyle(enabled ? RoomTheme.leaf : RoomTheme.muted)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(RoomTheme.ink)
                        .accessibilityHidden(true)
                }
                .font(RoomTheme.body())
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
                .background(enabled ? RoomTheme.fieldSurface : RoomTheme.surfaceMuted,
                            in: RoundedRectangle(cornerRadius: RoomTheme.radius))
                .overlay(RoundedRectangle(cornerRadius: RoomTheme.radius)
                    .stroke(enabled ? RoomTheme.fieldBorder : RoomTheme.border))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .accessibilityValue(selectedLabel)
            .accessibilityIdentifier(label)
        } else {
            Picker(label, selection: $selection) { options }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityLabel(label)
                .accessibilityIdentifier(label)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct RoomSwitch: View {
    @Environment(\.roomControlAppearance) private var appearance
    @Environment(\.isEnabled) private var enabled
    let label: String
    @Binding var isOn: Bool

    init(_ label: String, isOn: Binding<Bool>) {
        self.label = label
        _isOn = isOn
    }

    var body: some View {
        if appearance == .roomlings {
            HStack(spacing: 12) {
                Text(label)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityHidden(true)
                StyledRoomSwitch(label: label, isOn: $isOn)
                    .fixedSize()
            }
            .frame(minHeight: 44)
            .opacity(enabled ? 1 : 0.5)
        } else {
            Toggle(label, isOn: $isOn)
        }
    }
}

private struct StyledRoomSwitch: UIViewRepresentable {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    let label: String
    @Binding var isOn: Bool

    func makeCoordinator() -> Coordinator { Coordinator(isOn: $isOn) }

    func makeUIView(context: Context) -> UISwitch {
        let control = UISwitch()
        control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        return control
    }

    func updateUIView(_ control: UISwitch, context: Context) {
        context.coordinator.isOn = $isOn
        control.accessibilityLabel = label
        control.isEnabled = enabled
        control.semanticContentAttribute = layoutDirection == .rightToLeft ? .forceRightToLeft : .forceLeftToRight
        if control.isOn != isOn { control.setOn(isOn, animated: !reduceMotion) }
        control.onTintColor = UIColor(RoomTheme.sage)
        control.thumbTintColor = UIColor(isOn ? RoomTheme.paper : RoomTheme.muted)
        control.tintColor = UIColor(RoomTheme.fieldBorder)
        control.backgroundColor = UIColor(isOn ? RoomTheme.sage : RoomTheme.fieldSurface)
        control.layer.cornerRadius = control.intrinsicContentSize.height / 2
        control.layer.borderWidth = 1
        control.layer.borderColor = UIColor(isOn ? RoomTheme.sage : RoomTheme.fieldBorder).cgColor
        control.clipsToBounds = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UISwitch, context: Context) -> CGSize? {
        uiView.intrinsicContentSize
    }

    @MainActor
    final class Coordinator: NSObject {
        var isOn: Binding<Bool>

        init(isOn: Binding<Bool>) { self.isOn = isOn }

        @objc func changed(_ control: UISwitch) { isOn.wrappedValue = control.isOn }
    }
}

struct RoomSegmentedPicker<Selection: Hashable>: View {
    @Environment(\.roomControlAppearance) private var appearance
    @Environment(\.isEnabled) private var enabled
    @Environment(\.layoutDirection) private var layoutDirection
    @Binding var selection: Selection
    @FocusState private var focused: Selection?
    let label: String
    let options: [Selection]
    let title: (Selection) -> String

    init(_ label: String, selection: Binding<Selection>, options: [Selection], title: @escaping (Selection) -> String) {
        self.label = label
        _selection = selection
        self.options = options
        self.title = title
    }

    var body: some View {
        if appearance == .roomlings {
            HStack(spacing: 6) {
                ForEach(options, id: \.self) { option in
                    Button { selection = option } label: {
                        Text(title(option))
                            .font(RoomTheme.body(14).weight(.semibold))
                            .foregroundStyle(RoomTheme.ink)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(selection == option ? RoomTheme.leafSoft : Color.clear,
                                        in: RoundedRectangle(cornerRadius: RoomTheme.radius))
                            .overlay(RoundedRectangle(cornerRadius: RoomTheme.radius)
                                .stroke(selection == option ? RoomTheme.border : Color.clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focused($focused, equals: option)
                    .onKeyPress(.leftArrow) { step(layoutDirection == .rightToLeft ? 1 : -1) }
                    .onKeyPress(.rightArrow) { step(layoutDirection == .rightToLeft ? -1 : 1) }
                }
            }
            .padding(4)
            .background(RoomTheme.surface, in: RoundedRectangle(cornerRadius: RoomTheme.radius + 2))
            .overlay(RoundedRectangle(cornerRadius: RoomTheme.radius + 2).stroke(RoomTheme.border))
            .opacity(enabled ? 1 : 0.5)
            .accessibilityRepresentation { systemPicker }
        } else {
            systemPicker
        }
    }

    private var systemPicker: some View {
        Picker(label, selection: $selection) {
            ForEach(options, id: \.self) { option in Text(title(option)).tag(option) }
        }
        .pickerStyle(.segmented)
    }

    private func step(_ direction: Int) -> KeyPress.Result {
        guard enabled, let index = options.firstIndex(of: selection), options.indices.contains(index + direction) else {
            return .ignored
        }
        let next = options[index + direction]
        selection = next
        focused = next
        return .handled
    }
}
