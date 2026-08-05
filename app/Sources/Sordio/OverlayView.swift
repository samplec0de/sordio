import SwiftUI
import SordioCore

final class OverlayModel: ObservableObject {
    @Published var state: OverlayState = .noBridge
    @Published var isPending: Bool = false
    @Published var level: Float = 0            // 0…1
    @Published var speakingWhileMuted = false
    @Published var flash = false
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    var onToggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbolName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(contentTint)
                .frame(width: 20)

            if isControllable {
                LevelMeter(level: model.level, tint: contentTint)
                    .frame(width: 46, height: 14)
            } else {
                Text(caption)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(model.flash ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            // Нажатие вхолостую красит всю плашку сплошной заливкой, а не только
            // рамку — контур в 1–2 пункта неразличим боковым зрением, а заметность
            // здесь — единственная обратная связь на нажатие хоткея.
            Capsule().fill(model.flash ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.ultraThinMaterial))
                .overlay(Capsule().strokeBorder(borderColor, lineWidth: model.flash ? 2 : 1))
        )
        .opacity(model.isPending ? 0.65 : 1)
        .animation(.easeInOut(duration: 0.15), value: model.isPending)
        .animation(.easeInOut(duration: 0.15), value: model.flash)
        .contentShape(Capsule())
        .onTapGesture(perform: onToggle)
        .help(caption)
    }

    private var isControllable: Bool {
        model.state == .muted || model.state == .unmuted
    }

    /// Цвет иконки/текста/делений — во время подсветки белый для контраста
    /// со сплошной оранжевой заливкой фона.
    private var contentTint: Color {
        model.flash ? .white : tint
    }

    private var symbolName: String {
        switch model.state {
        case .unmuted: return "mic.fill"
        case .muted: return "mic.slash.fill"
        case .noBridge: return "bolt.horizontal.circle"
        case .noCall: return "mic.slash"
        case .buttonNotFound: return "questionmark.circle"
        }
    }

    private var caption: String {
        switch model.state {
        case .unmuted: return "Микрофон включён"
        case .muted: return model.speakingWhileMuted ? "Вас не слышно" : "Микрофон выключен"
        case .noBridge: return "Нет связи с браузером"
        case .noCall: return "Нет звонка"
        case .buttonNotFound: return "Кнопка не найдена"
        }
    }

    private var tint: Color {
        switch model.state {
        case .unmuted: return .green
        case .muted: return model.speakingWhileMuted ? .orange : .red
        case .noBridge, .noCall, .buttonNotFound: return .secondary
        }
    }

    private var borderColor: Color {
        // На сплошной оранжевой заливке сам оранжевый контур не виден — во время
        // подсветки нужен светлый ободок, чтобы капсула не сливалась с фоном за ней.
        model.flash ? .white.opacity(0.85) : tint.opacity(0.35)
    }
}

/// Индикатор уровня из восьми делений — дёшево рисуется и хорошо читается краем глаза.
private struct LevelMeter: View {
    var level: Float
    var tint: Color

    var body: some View {
        GeometryReader { geo in
            let count = 8
            let spacing: CGFloat = 2
            let barWidth = (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count)
            HStack(spacing: spacing) {
                ForEach(0..<count, id: \.self) { index in
                    let threshold = Float(index + 1) / Float(count)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(level >= threshold ? tint : tint.opacity(0.18))
                        .frame(width: barWidth)
                }
            }
        }
    }
}
