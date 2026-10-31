import SwiftUI
import ServiceManagement

// MARK: - Right-Aligned Switch Toggle Style
struct RightAlignedSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
                .accessibilityHidden(true)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        configuration.isOn.toggle()
                    }
                }
            Spacer(minLength: 8)
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}

// MARK: - Main Settings Page
@MainActor
struct AgentSettingsPage: View {
    @ObservedObject var model: ControlCenterModel
    @ObservedObject private var preferences = AppPreferences.shared

    @AppStorage("AgentDock_SettingsSoundExpanded") private var isSoundExpanded = true

    @State private var previewActivity = [
        "Analyzing project structure",
        "Refactoring layout components",
        "Running automated tests"
    ].randomElement() ?? "Analyzing project structure"

    private var wallpaperImage: NSImage? {
        NSImage(named: NSImage.Name("wallpaper"))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                Text("Settings")
                    .font(.agentHeading(size: 19, weight: .bold))
                    .foregroundColor(AgentTheme.foreground)
                    .padding(.bottom, 2)

                // 1. Notch HUD Section
                notchSection

                // 2. Sound Effects Accordion Card
                soundSection

                // 3. General Section
                generalSection

                // 4. Support Section
                supportSection
            }
            .toggleStyle(RightAlignedSwitchToggleStyle())
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 28)
        }
    }

    // MARK: - Notch HUD Section
    private var notchSection: some View {
        let previewGeometry = NotchGeometry.current(
            displayID: preferences.displayID,
            showsBottomText: preferences.showsBottomText,
            compactness: preferences.notchCompactness,
            style: preferences.notchStyle
        )

        return AgentSettingsSection(
            title: "Notch",
            icon: .custom(.activity)
        ) {
            // Master Notch Toggle
            AgentGroupedRow(position: .top) {
                Toggle(isOn: $preferences.notchEnabled) {
                    Text("Show activity in notch")
                        .font(.agentSans(size: 12, weight: .medium))
                }
            }

            // Live Preview Canvas
            AgentGroupedRow(position: .middle) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        AppIcon(.preview, size: 18)
                            .foregroundColor(preferences.notchEnabled ? AgentTheme.agentBlue : AgentTheme.mutedForeground)
                        Text("Live Preview")
                            .font(.agentHeading(size: 12.5, weight: .semibold))
                            .foregroundColor(preferences.notchEnabled ? AgentTheme.foreground : AgentTheme.mutedForeground)

                        Spacer()

                        Text(preferences.notchEnabled ? "Active" : "Disabled")
                            .font(.agentSans(size: 10, weight: .medium))
                            .foregroundColor(preferences.notchEnabled ? AgentTheme.mutedForeground : AgentTheme.warning)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(Capsule().fill(AgentTheme.muted))
                    }

                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: max(previewGeometry.totalHeight + 80, 160))
                        .background {
                            if let wallpaper = wallpaperImage {
                                Image(nsImage: wallpaper)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            } else {
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.85, green: 0.35, blue: 0.40),
                                        Color(red: 0.50, green: 0.20, blue: 0.55),
                                        Color(red: 0.20, green: 0.25, blue: 0.60)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            }
                        }
                        .overlay(alignment: .top) {
                            if preferences.notchEnabled {
                                NotchPillView(geometry: previewGeometry, previewText: previewActivity)
                                    .frame(width: previewGeometry.totalWidth, height: previewGeometry.totalHeight)
                                    .allowsHitTesting(false)
                            } else {
                                VStack(spacing: 6) {
                                    Image(systemName: "eye.slash")
                                        .font(.system(size: 20))
                                        .foregroundColor(Color.white.opacity(0.6))
                                    Text("Notch HUD disabled")
                                        .font(.agentSans(size: 11.5, weight: .medium))
                                        .foregroundColor(Color.white.opacity(0.8))
                                }
                                .padding(.top, 45)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8)
                                .allowsHitTesting(false)
                        )
                        .opacity(preferences.notchEnabled ? 1.0 : 0.6)
                        // Clipping the wallpaper does not constrain its hit-testing area.
                        .allowsHitTesting(false)
                }
            }

            // Subordinate Controls (disabled when notch HUD is turned off)
            AgentGroupedRow(position: .middle) {
                HStack {
                    Text("Display")
                        .font(.agentSans(size: 12, weight: .medium))
                    Spacer()
                    Picker("Display", selection: $preferences.displayID) {
                        Text("Follow active display").tag("")
                        ForEach(model.displays) { display in
                            Text(display.name).tag(display.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
            }
            .disabled(!preferences.notchEnabled)
            .opacity(preferences.notchEnabled ? 1 : 0.45)

            AgentGroupedRow(position: .middle) {
                HStack {
                    Text("Layout")
                        .font(.agentSans(size: 12, weight: .medium))
                    Spacer()
                    Picker("Layout", selection: $preferences.showsBottomText) {
                        Text("Activity text").tag(true)
                        Text("Compact indicator").tag(false)
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }
            }
            .disabled(!preferences.notchEnabled)
            .opacity(preferences.notchEnabled ? 1 : 0.45)

            AgentGroupedRow(position: .middle) {
                HStack {
                    Text("Shape")
                        .font(.agentSans(size: 12, weight: .medium))
                    Spacer()
                    Picker("Shape", selection: $preferences.notchStyle) {
                        ForEach(NotchStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!preferences.showsBottomText || !preferences.notchEnabled)
                    .frame(width: 220)
                }
            }
            .disabled(!preferences.notchEnabled)
            .opacity(preferences.notchEnabled ? 1 : 0.45)

            AgentGroupedRow(position: .middle) {
                HStack {
                    HStack(spacing: 6) {
                        Text("Compactness")
                            .font(.agentSans(size: 12, weight: .medium))
                        Text("\(Int(preferences.notchCompactness * 100))%")
                            .font(.agentHeading(size: 11.5, weight: .semibold))
                            .foregroundColor(AgentTheme.primary)
                    }
                    Spacer()
                    Slider(value: $preferences.notchCompactness, in: 0...1, step: 0.05)
                        .accessibilityLabel("Compactness")
                        .frame(width: 160)
                }
            }
            .disabled(!preferences.notchEnabled)
            .opacity(preferences.notchEnabled ? 1 : 0.45)

            AgentGroupedRow(position: .bottom) {
                HStack {
                    HStack(spacing: 6) {
                        Text("Scroll speed")
                            .font(.agentSans(size: 12, weight: .medium))
                        Text(String(format: "%.1fx", preferences.marqueeSpeed))
                            .font(.agentHeading(size: 11.5, weight: .semibold))
                            .foregroundColor(AgentTheme.primary)
                    }
                    Spacer()
                    Slider(value: $preferences.marqueeSpeed, in: 0.5...2, step: 0.25)
                        .accessibilityLabel("Scroll speed")
                        .disabled(!preferences.showsBottomText || !preferences.notchEnabled)
                        .frame(width: 160)
                }
            }
            .disabled(!preferences.notchEnabled)
            .opacity(preferences.notchEnabled ? 1 : 0.45)
        }
    }

    // MARK: - Sound Effects Accordion Card
    private var soundSection: some View {
        AgentGroupedCard {
            // Master row: Icon, title, toggle, and accordion chevron
            AgentGroupedRow(position: isSoundExpanded ? .top : .single) {
                HStack(spacing: 12) {
                    HStack(spacing: 10) {
                        AppIcon(.system("speaker.wave.2"), size: 18)
                            .foregroundStyle(AgentTheme.primary)

                        Text("Sound effects")
                            .font(.agentHeading(size: 13.5, weight: .semibold))
                            .foregroundStyle(AgentTheme.foreground)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            isSoundExpanded.toggle()
                        }
                    }

                    Spacer()

                    HStack(spacing: 10) {
                        Toggle("Sound effects", isOn: $preferences.soundEffectsEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)

                        Button {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                isSoundExpanded.toggle()
                            }
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(isSoundExpanded ? AgentTheme.primary : AgentTheme.mutedForeground)
                                .rotationEffect(.degrees(isSoundExpanded ? 90 : 0))
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(isSoundExpanded ? "Collapse sound controls" : "Expand sound controls")
                    }
                }
            }

            if isSoundExpanded {
                // Detail row 1: Agent starts
                AgentGroupedRow(position: .middle) {
                    HStack {
                        Toggle(isOn: $preferences.soundOnStart) {
                            Text("Agent starts")
                                .font(.agentSans(size: 12, weight: .medium))
                        }
                        Button {
                            AgentSoundService.shared.previewSound(.start)
                        } label: {
                            Image(systemName: "speaker.wave.1.fill")
                                .font(.system(size: 11))
                                .foregroundColor(AgentTheme.mutedForeground)
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Preview start sound")
                    }
                }
                .disabled(!preferences.soundEffectsEnabled)
                .opacity(preferences.soundEffectsEnabled ? 1 : 0.45)

                // Detail row 2: Questions & approvals
                AgentGroupedRow(position: .middle) {
                    HStack {
                        Toggle(isOn: $preferences.soundOnQuestion) {
                            Text("Questions & approvals")
                                .font(.agentSans(size: 12, weight: .medium))
                        }
                        Button {
                            AgentSoundService.shared.previewSound(.question)
                        } label: {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.system(size: 11))
                                .foregroundColor(AgentTheme.mutedForeground)
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Preview question chime")
                    }
                }
                .disabled(!preferences.soundEffectsEnabled)
                .opacity(preferences.soundEffectsEnabled ? 1 : 0.45)

                // Detail row 3: Agent stops
                AgentGroupedRow(position: .bottom) {
                    HStack {
                        Toggle(isOn: $preferences.soundOnStop) {
                            Text("Agent stops")
                                .font(.agentSans(size: 12, weight: .medium))
                        }
                        Button {
                            AgentSoundService.shared.previewSound(.stop)
                        } label: {
                            Image(systemName: "speaker.wave.3.fill")
                                .font(.system(size: 11))
                                .foregroundColor(AgentTheme.warning)
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Preview stop sound")
                    }
                }
                .disabled(!preferences.soundEffectsEnabled)
                .opacity(preferences.soundEffectsEnabled ? 1 : 0.45)
            }
        }
    }

    // MARK: - General Section
    private var generalSection: some View {
        AgentSettingsSection(
            title: "General",
            icon: .system("gearshape")
        ) {
            AgentGroupedRow(position: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: Binding(
                        get: { model.launchAtLogin },
                        set: { enabled in Task { await model.setLaunchAtLogin(enabled) } }
                    )) {
                        Text("Launch at login")
                            .font(.agentSans(size: 12, weight: .medium))
                    }
                    .disabled(model.updatingLogin)

                    if model.loginStatus == .requiresApproval {
                        Pushable3DButton(variant: .warning, cornerRadius: AgentTheme.radiusXs) {
                            SMAppService.openSystemSettingsLoginItems()
                        } content: {
                            Text("Open Login Items")
                                .font(.agentSans(size: 11, weight: .semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4.5)
                        }
                    }
                }
            }

            AgentGroupedRow(position: .bottom) {
                HStack {
                    Text("Appearance")
                        .font(.agentSans(size: 12, weight: .medium))
                    Spacer()
                    Picker("Appearance", selection: $preferences.appearance) {
                        ForEach(AppPreferences.Appearance.allCases) { appearance in
                            Text(appearance.rawValue).tag(appearance)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
            }
        }
    }

    // MARK: - Support Section
    private var supportSection: some View {
        AgentSettingsSection(
            title: "Support",
            icon: .custom(.shieldCheck)
        ) {
            AgentGroupedRow(position: .single) {
                HStack(spacing: 8) {
                    Pushable3DButton(variant: .secondary, cornerRadius: AgentTheme.radiusXs) {
                        model.copyDiagnostics()
                    } content: {
                        Text(model.diagnosticsCopied ? "Diagnostics copied" : "Copy diagnostics")
                            .font(.agentSans(size: 11, weight: .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4.5)
                    }

                    Pushable3DButton(variant: .secondary, cornerRadius: AgentTheme.radiusXs) {
                        MainWindowController.shared.startOnboarding()
                    } content: {
                        Text("Rerun setup wizard")
                            .font(.agentSans(size: 11, weight: .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4.5)
                    }
                }
            }
        }
    }
}
