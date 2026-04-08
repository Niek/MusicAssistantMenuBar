import AppKit
import SwiftUI

struct MarqueeText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let text: String
    let textColor: Color
    let fontSize: CGFloat
    let weight: Font.Weight

    private let gap: CGFloat = 30
    private let speed: CGFloat = 36
    private let frameInterval = 1.0 / 24.0
    private let fadeWidth: CGFloat = 12

    @State private var cachedTextWidth: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let availableWidth = max(geometry.size.width, 1)
            let contentWidth = cachedTextWidth ?? measureTextWidth()
            let shouldScroll = !reduceMotion && contentWidth > availableWidth

            Group {
                if shouldScroll {
                    TimelineView(.animation(minimumInterval: frameInterval, paused: false)) { context in
                        let distance = contentWidth + gap
                        let cycleDuration = TimeInterval(distance / speed)
                        let elapsed = context.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: cycleDuration)
                        let offset = -CGFloat(elapsed) * speed

                        HStack(spacing: gap) {
                            label
                            label
                        }
                        .offset(x: offset)
                    }
                    .mask(edgeFadeMask)
                } else {
                    label
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .clipped()
        }
        .onAppear {
            cachedTextWidth = measureTextWidth()
        }
        .onChange(of: text) { _ in
            cachedTextWidth = measureTextWidth()
        }
    }

    private var edgeFadeMask: some View {
        GeometryReader { geometry in
            let fraction = min(fadeWidth / max(geometry.size.width, 1), 0.5)
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: fraction),
                    .init(color: .black, location: 1 - fraction),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }

    private var label: some View {
        Text(text)
            .font(.system(size: fontSize, weight: weight, design: .rounded))
            .foregroundStyle(textColor)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func measureTextWidth() -> CGFloat {
        let nsWeight: NSFont.Weight = switch weight {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .regular
        }

        let font = NSFont.systemFont(ofSize: fontSize, weight: nsWeight)
        return (text as NSString).size(withAttributes: [.font: font]).width
    }
}
