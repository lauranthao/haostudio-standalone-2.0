// HAo Studio 2.0 — equalizer page (S2-C leg).
//
// 10-band EQ (Flutter equalizer_page.dart): response preview curve,
// one slider row per band, preamp, Beans preset grid, custom presets,
// AutoEq headphone presets. The sliders are horizontal list rows,
// one per band — not vertical sliders.
//
// Normalisation lives here too, gated on EQ: loudness can only be
// measured while the equalizer is on (plan §七.3), so the switch is
// disabled unless EQ is enabled, with the reason shown.

import SwiftUI

struct MusicEqualizerView: View {
    @StateObject private var eqVM = MusicEqualizerViewModel()
    @State private var newPresetName = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.haoTheme) private var theme

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    enableRow
                    responseCard
                    bandsCard
                    preampRow
                    presetCard
                    autoEqCard
                    normalizationCard
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .background(theme.scaffoldBackground)
            .navigationTitle("均衡器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    // MARK: - Enable

    private var enableRow: some View {
        Toggle("均衡器", isOn: $eqVM.enabled)
            .font(.haoCalloutStrong)
            .foregroundStyle(theme.textPrimary)
            .tint(theme.accent)
    }

    // MARK: - Response preview

    private var responseCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("响应曲线")
                .font(.haoDenseTitle)
                .foregroundStyle(theme.textPrimary)
            EQCurveView(gains: eqVM.previewGains)
                .frame(height: 90)
            HStack {
                Text("31 Hz").font(.haoCaption2).foregroundStyle(theme.textMuted)
                Spacer()
                Text("1 kHz").font(.haoCaption2).foregroundStyle(theme.textMuted)
                Spacer()
                Text("16 kHz").font(.haoCaption2).foregroundStyle(theme.textMuted)
            }
        }
        .padding(16)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    // MARK: - Bands

    private var bandsCard: some View {
        VStack(spacing: 0) {
            ForEach(0..<MusicEQMath.bandCount, id: \.self) { band in
                HStack(spacing: 12) {
                    Text(MusicEQMath.frequencyLabel(MusicEQMath.bandFrequencies[band]))
                        .font(.haoFootnoteMedium)
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 52, alignment: .leading)
                    Slider(
                        value: Binding(
                            get: { eqVM.gains[band] },
                            set: { eqVM.setGain(band: band, value: $0) }
                        ),
                        in: -MusicEQMath.maximumGain...MusicEQMath.maximumGain,
                        step: MusicEQMath.gainStep
                    )
                    .tint(theme.accent)
                    .disabled(!eqVM.enabled)
                    Text(String(format: "%+.1f", eqVM.gains[band]))
                        .font(.haoCaptionMedium)
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 44, alignment: .trailing)
                }
                .padding(.vertical, 6)
                if band < MusicEQMath.bandCount - 1 {
                    Divider().background(theme.hairline)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    // MARK: - Preamp

    private var preampRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("前级增益")
                    .font(.haoDenseTitle)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Text(String(format: "%+.1f dB", eqVM.preamp))
                    .font(.haoFootnote)
                    .foregroundStyle(theme.textSecondary)
            }
            Slider(
                value: Binding(
                    get: { eqVM.preamp },
                    set: { eqVM.setPreamp($0) }
                ),
                in: -MusicEQMath.maximumGain...MusicEQMath.maximumGain,
                step: MusicEQMath.gainStep
            )
            .tint(theme.accent)
            .disabled(!eqVM.enabled)
        }
        .padding(16)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    // MARK: - Presets

    private var presetCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("预设")
                    .font(.haoDenseTitle)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Text(eqVM.currentPresetName)
                    .font(.haoFootnote)
                    .foregroundStyle(theme.textSecondary)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(MusicEqualizerPreset.allCases, id: \.rawValue) { preset in
                    let selected = !eqVM.isCustom && eqVM.selectedPreset == preset
                    Button(action: { eqVM.applyPreset(preset) }) {
                        HStack(spacing: 4) {
                            if selected {
                                Image(systemName: "checkmark")
                                    .font(.haoCaptionStrong)
                            }
                            Text(preset.displayName)
                                .font(.haoCaptionMedium)
                        }
                            .foregroundStyle(selected ? theme.accent : theme.textPrimary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                            .background(
                                selected ? theme.accentSoft : theme.surfaceStrong,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(selected ? theme.accent : theme.hairline, lineWidth: selected ? 0.8 : 0.5)
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(!eqVM.enabled)
                }
            }
            if !eqVM.customPresets.isEmpty {
                Divider().background(theme.hairline)
                Text("我的预设")
                    .font(.haoFootnoteStrong)
                    .foregroundStyle(theme.textSecondary)
                ForEach(eqVM.customPresets, id: \.name) { preset in
                    HStack {
                        Button(action: { eqVM.applyCustomPreset(preset) }) {
                            Text(preset.name)
                                .font(.haoRowSubtitle)
                                .foregroundStyle(theme.textPrimary)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Button(action: { eqVM.deleteCustomPreset(preset) }) {
                            Image(systemName: "trash")
                                .font(.haoFootnote)
                                .foregroundStyle(theme.textMuted)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Divider().background(theme.hairline)
            HStack(spacing: 10) {
                TextField("保存为自定义预设", text: $newPresetName)
                    .font(.haoRowSubtitle)
                Button("保存") {
                    eqVM.saveCurrentAsCustomPreset(named: newPresetName)
                    newPresetName = ""
                }
                .foregroundStyle(theme.accent)
                .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("重置") { eqVM.resetToFlat() }
                    .foregroundStyle(theme.accent)
            }
        }
        .padding(16)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    // MARK: - AutoEq

    private var autoEqCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("耳机预设（AutoEq）")
                .font(.haoDenseTitle)
                .foregroundStyle(theme.textPrimary)
            Text("社区风格修正的近似值，不是完整测量曲线。")
                .font(.haoCaption)
                .foregroundStyle(theme.textSecondary)
            ForEach(MusicAutoEqPreset.all, id: \.name) { preset in
                Button(action: { eqVM.applyAutoEq(preset) }) {
                    HStack {
                        Text(preset.name)
                            .font(.haoRowSubtitle)
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                        if eqVM.selectedAutoEqName == preset.name {
                            Image(systemName: "checkmark")
                                .foregroundStyle(theme.accent)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!eqVM.enabled)
            }
        }
        .padding(16)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    // MARK: - Normalization

    private var normalizationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("音量归一化", isOn: $eqVM.normalizationEnabled)
                .font(.haoDenseTitle)
                .foregroundStyle(theme.textPrimary)
                .tint(theme.accent)
                .disabled(!eqVM.normalizationAvailable)
            Text("归一化需开启均衡器才能测响度；只压低不抬升，第二遍播放起生效。")
                .font(.haoCaption)
                .foregroundStyle(theme.textSecondary)
            HStack {
                Text("归一化强度")
                    .font(.haoRowSubtitle)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Stepper(value: $eqVM.normalizationStrength, in: 0...2) {
                    Text("\(eqVM.normalizationStrength)")
                        .font(.haoRowSubtitle)
                        .foregroundStyle(theme.textSecondary)
                }
                .disabled(!eqVM.normalizationAvailable || !eqVM.normalizationEnabled)
            }
        }
        .padding(16)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

/// Response preview curve: 10 band points joined by a line, filled
/// under the zero line with the accent wash.
struct EQCurveView: View {
    var gains: [Double]
    @Environment(\.haoTheme) private var theme

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let stepX = gains.count > 1 ? width / CGFloat(gains.count - 1) : width
            let midY = height / 2
            let scale = (height / 2 - 4) / CGFloat(MusicEQMath.maximumGain)
            let points = gains.enumerated().map { index, gain in
                CGPoint(x: CGFloat(index) * stepX, y: midY - CGFloat(gain) * scale)
            }
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: midY))
                    path.addLine(to: CGPoint(x: width, y: midY))
                }
                .stroke(theme.hairline, lineWidth: 0.5)
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    for point in points.dropFirst() { path.addLine(to: point) }
                }
                .stroke(theme.accent, lineWidth: 1.5)
            }
        }
    }
}
