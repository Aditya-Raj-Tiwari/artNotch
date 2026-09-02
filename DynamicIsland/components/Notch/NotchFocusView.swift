/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import AppKit
import Defaults
import SwiftUI

/// Focus tab: a front end for Raycast Focus with the same form Raycast uses (goal, duration
/// or no limit, categories, block/allow). Raycast does the app and website blocking; the tab
/// mirrors the running session, whether it was started here or in Raycast, with a Complete
/// control. Monochrome like the rest of the shell.
struct NotchFocusView: View {
    @EnvironmentObject var vm: DynamicIslandViewModel
    @ObservedObject var focusManager = RaycastFocusManager.shared
    @ObservedObject var timerManager = TimerManager.shared

    @Default(.raycastFocusLastGoal) private var goal
    @Default(.raycastFocusDuration) private var storedDuration
    @Default(.raycastFocusOpenEnded) private var isOpenEnded
    @Default(.raycastFocusMode) private var mode
    @Default(.raycastFocusSelectedCategories) private var selectedCategories
    @Default(.raycastFocusCustomCategories) private var customCategories

    @State private var hours = 0
    @State private var minutes = 25
    @State private var seconds = 0
    @State private var isSyncingDuration = false
    @FocusState private var goalFieldFocused: Bool

    private let categoryColumnWidth: CGFloat = 210

    private var showsActiveSession: Bool {
        focusManager.session != nil || timerManager.isRaycastFocusSession
    }

    var body: some View {
        HStack(alignment: .top, spacing: showsActiveSession ? 0 : 20) {
            leftColumn
            if !showsActiveSession {
                Divider()
                    .frame(height: max(0, maxTabContentHeight - 8))
                    .opacity(0.2)
                categoryColumn
            }
        }
        .frame(maxHeight: maxTabContentHeight, alignment: .top)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .onAppear { syncDuration(with: storedDuration) }
        .onChange(of: storedDuration) { _, newValue in syncDuration(with: newValue) }
        .onChange(of: hours) { _, _ in storeDuration() }
        .onChange(of: minutes) { _, _ in storeDuration() }
        .onChange(of: seconds) { _, _ in storeDuration() }
    }

    // MARK: - Columns

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsActiveSession {
                Spacer(minLength: 0)
                activeSessionCard
                Spacer(minLength: 0)
            } else {
                composer
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxHeight: maxTabContentHeight, alignment: .top)
        .padding(.bottom, 2)
    }

    private var categoryColumn: some View {
        let categories = RaycastFocusCategory.all(includingCustom: customCategories)
        let computedHeight = CGFloat(categories.count) * 40 + 4
        let listHeight = min(max(0, maxTabContentHeight - 16), computedHeight)

        return VStack(alignment: .leading, spacing: 6) {
            if let error = focusManager.lastError {
                Text(error)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ZStack {
                List {
                    ForEach(categories) { category in
                        FocusCategoryRow(
                            category: category,
                            isSelected: selectedCategories.contains(category.id)
                        ) {
                            toggle(category.id)
                        }
                        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)

                LinearGradient(colors: [Color.black.opacity(0.65), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 16)
                    .allowsHitTesting(false)
                    .frame(maxHeight: .infinity, alignment: .top)

                LinearGradient(colors: [.clear, Color.black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 16)
                    .allowsHitTesting(false)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .frame(height: listHeight)
        }
        .frame(width: categoryColumnWidth, alignment: .leading)
        .frame(maxHeight: maxTabContentHeight, alignment: .top)
        .padding(.bottom, 2)
    }

    // MARK: - Composer (no session)

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            goalField

            HStack(alignment: .top, spacing: 14) {
                DurationInputRow(hours: $hours, minutes: $minutes, seconds: $seconds, fieldWidth: 56)
                    .opacity(isOpenEnded ? 0.35 : 1)
                    .disabled(isOpenEnded)

                noLimitChip
                    .padding(.top, 7)
            }

            HStack(spacing: 10) {
                startButton
                modeChip
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private var goalField: some View {
        HStack(spacing: 8) {
            Image(systemName: "target")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
            TextField(String(localized: "What are you focusing on?"), text: $goal)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white)
                .tint(.white)
                .focused($goalFieldFocused)
                .onSubmit(startSession)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var noLimitChip: some View {
        FocusChip(
            title: String(localized: "No limit"),
            systemImage: "infinity",
            isSelected: isOpenEnded,
            help: String(localized: "Run until you complete the session")
        ) {
            withAnimation(.smooth(duration: 0.2)) {
                isOpenEnded.toggle()
            }
        }
    }

    private var modeChip: some View {
        FocusChip(
            title: mode.title,
            systemImage: mode == .block ? "hand.raised" : "checkmark.shield",
            isSelected: false,
            help: mode.summary
        ) {
            withAnimation(.smooth(duration: 0.2)) {
                mode = mode == .block ? .allow : .block
            }
        }
        .frame(width: 96)
    }

    private var startButton: some View {
        Button(action: startSession) {
            Label(
                focusManager.isStartPending ? String(localized: "Starting…") : String(localized: "Start Focus"),
                systemImage: "play.fill"
            )
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(isStartDisabled ? 0.35 : 0.92))
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .disabled(isStartDisabled)
    }

    private var isStartDisabled: Bool {
        if focusManager.isStartPending { return true }
        if !focusManager.isAvailable { return true }
        return !isOpenEnded && customDuration <= 0
    }

    // MARK: - Active session

    private var activeSessionCard: some View {
        let session = focusManager.session
        let openEnded = session?.isOpenEnded ?? timerManager.isOpenEnded

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                TimerControlButton(
                    icon: "checkmark",
                    foreground: .black,
                    background: Color.white.opacity(0.9),
                    accessibilityLabel: String(localized: "Complete"),
                    action: focusManager.completeSession
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text(session?.goal ?? timerManager.timerName)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    HStack(spacing: 6) {
                        badge(String(localized: "Raycast Focus"))
                        if let session {
                            badge(session.mode.title)
                            if !session.blockedApps.isEmpty {
                                badge(String(localized: "\(session.blockedApps.count) apps"))
                            }
                            if !session.blockedWebsites.isEmpty {
                                badge(String(localized: "\(session.blockedWebsites.count) sites"))
                            }
                        }
                        if focusManager.isPaused {
                            badge(String(localized: "Paused"))
                        }
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(timerManager.formattedRemainingTime())
                        .font(.system(size: 36, weight: .black, design: .monospaced))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(openEnded ? String(localized: "elapsed") : String(localized: "remaining"))
                        .font(.system(size: 10, weight: .medium))
                        .textCase(.uppercase)
                        .tracking(0.6)
                        .foregroundStyle(.white.opacity(0.45))
                }
            }

            if !openEnded {
                Capsule()
                    .fill(Color.white.opacity(0.12))
                    .frame(height: 4)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Color.white)
                            .frame(height: 4)
                            .scaleEffect(x: CGFloat(max(0, min(timerManager.progress, 1))), y: 1, anchor: .leading)
                            .animation(.linear(duration: 0.3), value: timerManager.progress)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 4)
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.white.opacity(0.10))
            .clipShape(Capsule())
            .lineLimit(1)
    }

    // MARK: - Actions & helpers

    private var customDuration: TimeInterval {
        TimeInterval(hours * 3600 + minutes * 60 + seconds)
    }

    private func startSession() {
        guard !isStartDisabled else { return }
        goalFieldFocused = false
        focusManager.startSession(
            goal: goal,
            duration: isOpenEnded ? nil : customDuration,
            categoryIds: selectedCategories,
            mode: mode
        )
    }

    private func toggle(_ categoryId: String) {
        if let index = selectedCategories.firstIndex(of: categoryId) {
            selectedCategories.remove(at: index)
        } else {
            selectedCategories.append(categoryId)
        }
    }

    private func syncDuration(with value: Double) {
        isSyncingDuration = true
        let components = TimerPreset.components(for: value)
        hours = components.hours
        minutes = components.minutes
        seconds = components.seconds
        isSyncingDuration = false
    }

    private func storeDuration() {
        guard !isSyncingDuration else { return }
        storedDuration = customDuration
    }

    private var resolvedNotchHeight: CGFloat {
        let height = vm.notchSize.height
        return height > 0 ? height : openNotchSize.height
    }

    private var headerHeight: CGFloat {
        max(24, vm.effectiveClosedNotchHeight)
    }

    private var maxTabContentHeight: CGFloat {
        let available = resolvedNotchHeight - headerHeight - 36
        return max(130, available)
    }
}

// MARK: - Pieces

private struct FocusChip: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSelected ? Color.black : Color.white.opacity(0.85))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.92) : Color.white.opacity(isHovering ? 0.14 : 0.10))
                )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .help(help)
        .onHover { hovering in isHovering = hovering }
    }
}

private struct FocusCategoryRow: View {
    let category: RaycastFocusCategory
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: category.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 22, height: 22)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())

                Text(category.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)

                Spacer(minLength: 8)

                ZStack {
                    Circle()
                        .fill(isSelected ? Color.white.opacity(0.9) : Color.clear)
                    Circle()
                        .stroke(Color.white.opacity(isSelected ? 0 : 0.25), lineWidth: 1.5)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.black)
                    }
                }
                .frame(width: 20, height: 20)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(isSelected ? 0.10 : (isHovering ? 0.07 : 0.04)))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovering = hovering }
    }
}

#Preview {
    NotchFocusView()
        .environmentObject(DynamicIslandViewModel())
        .frame(width: 600, height: 320)
        .background(.black)
}
