// HAo Studio 2.0 — launch splash, animation #4.
//
// Full spec: docs/splash-animation-4-spec.md (source: the old Swift
// splash implementation `layoutSplashOverlays` / `runSplashAnimation`,
// and the reference video). Implemented in SwiftUI with Animation.easeOut /
// easeInOut — NOT a translation of the old UIView.animate code.
//
// Timeline (total ~1.5s, white background, standard logo asset):
//   0.0–1.0s  logo fades in (alpha 0 -> 1), floats up 22pt, scales
//             0.97 -> 1.0 (ease-out)
//   0.15–1.0s soft shadow grows beneath it (alpha -> 1, scale 0.7 -> 1.0,
//             0.85s, ease-out)
//   0.7–1.0s  red dot fades/scales in (0.3s, ease-out)
//   0.9–1.5s  dot breathes once: scale 1 -> 1.12, glow alpha -> 0.55
//             (0.6s, ease-in-out)
//   1.5s      done: if ready, the whole splash fades out (0.3s — same
//             as the old `hideLoading` fade) and the app shell fades in;
//             if not ready, spinner + subtitle fade in (0.25s) and wait.
//
// Geometry (all from the spec, never hardcoded points):
// - Logo: 180 x 180, centred horizontally, centreY -30.
// - Shadow: 220 x 64, top = logo bottom - 4.
// - Red dot: diameter d = 0.069 x logo width, centre at
//   (0.678W, 0.409H) of the logo square, RGB(0.96, 0.20, 0.20),
//   initial scale 0.6.
// - Glow: g = 0.22 x logo width, same centre, radial gradient
//   (red maxAlpha 0.85 -> transparent), below the dot, code-generated
//   (SwiftUI RadialGradient — no extra asset).
// - Spinner + subtitle ("正在加载…", 14pt, grey): top = logo bottom + 92,
//   subtitle 8pt below the spinner. Shown ONLY if not ready at 1.5s.
//
// The spinner is grey, not red: the old code used .systemRed, but the
// iron law reserves red for the LIVE badge / recording dot — a loading
// spinner is not one of those.

import SwiftUI

struct SplashView: View {
    /// Whether the app shell is ready to show. Foundation: the parent
    /// passes `true` (no async init yet); later slices flip it when
    /// their startup work (e.g. store migration) finishes.
    @Binding var isReady: Bool
    /// Called after the 0.3s fade-out, when the splash may be removed.
    var onFinished: () -> Void

    // MARK: - Animation state (all start at the spec's initial values)

    @State private var logoOpacity: Double = 0
    @State private var logoOffsetY: CGFloat = 22
    @State private var logoScale: CGFloat = 0.97
    @State private var shadowOpacity: Double = 0
    @State private var shadowScale: CGFloat = 0.7
    @State private var dotOpacity: Double = 0
    @State private var dotInScale: CGFloat = 0.6
    @State private var dotBreathScale: CGFloat = 1.0
    @State private var glowOpacity: Double = 0
    @State private var showWaiting: Bool = false
    @State private var splashOpacity: Double = 1
    @State private var finished = false

    private let logoSize: CGFloat = 180

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()
                // Logo block: logo + shadow + dot + glow, positioned
                // exactly as the spec (centreY -30 from screen centre
                // is approximated by the Spacer balance + offset below).
                ZStack {
                    // Soft ground shadow under the logo.
                    Ellipse()
                        .fill(
                            RadialGradient(
                                colors: [Color.black.opacity(0.32), Color.black.opacity(0)],
                                center: .center,
                                startRadius: 0,
                                endRadius: 110
                            )
                        )
                        .frame(width: 220, height: 64)
                        .offset(y: logoSize / 2 - 4 + 32)
                        .opacity(shadowOpacity)
                        .scaleEffect(shadowScale)
                    Image("Logo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: logoSize, height: logoSize)
                        .opacity(logoOpacity)
                        .offset(y: logoOffsetY)
                        .scaleEffect(logoScale)
                        .overlay {
                            // Red dot + glow, positioned by PROPORTION
                            // of the logo square (0.678W / 0.409H),
                            // never hardcoded points.
                            GeometryReader { logoGeo in
                                let w = logoGeo.size.width
                                let h = logoGeo.size.height
                                let d = w * 0.069
                                let g = w * 0.22
                                let cx = w * 0.678
                                let cy = h * 0.409
                                ZStack {
                                    Circle()
                                        .fill(
                                            RadialGradient(
                                                colors: [
                                                    Color(red: 0.96, green: 0.20, blue: 0.20).opacity(0.85),
                                                    Color(red: 0.96, green: 0.20, blue: 0.20).opacity(0)
                                                ],
                                                center: .center,
                                                startRadius: 0,
                                                endRadius: g / 2
                                            )
                                        )
                                        .frame(width: g, height: g)
                                        .position(x: cx, y: cy)
                                        .opacity(glowOpacity)
                                    Circle()
                                        .fill(Color(red: 0.96, green: 0.20, blue: 0.20))
                                        .frame(width: d, height: d)
                                        .position(x: cx, y: cy)
                                        .opacity(dotOpacity)
                                        .scaleEffect(dotInScale * dotBreathScale)
                                }
                            }
                        }
                }
                .frame(width: logoSize, height: logoSize)
                .offset(y: -30)
                // Spinner + subtitle: only when not ready at 1.5s.
                // Always in layout (opacity 0 when hidden) so the logo
                // never jumps when the spinner appears — the old code
                // used fixed constraints for the same reason.
                VStack(spacing: 8) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.large)
                    Text("正在加载…")
                        .font(.haoRowSubtitle)
                        .foregroundStyle(.gray)
                }
                .padding(.top, 92)
                .opacity(showWaiting ? 1 : 0)
                Spacer()
            }
        }
        .opacity(splashOpacity)
        .onAppear(perform: startAnimation)
    }

    private func startAnimation() {
        // 0.0–1.0s: logo fade + float up + scale to 1.0 (ease-out).
        withAnimation(.easeOut(duration: 1.0).delay(0)) {
            logoOpacity = 1
            logoOffsetY = 0
            logoScale = 1.0
        }
        // 0.15–1.0s: shadow grows (0.85s, ease-out).
        withAnimation(.easeOut(duration: 0.85).delay(0.15)) {
            shadowOpacity = 1
            shadowScale = 1.0
        }
        // 0.7–1.0s: red dot fades/scales in (0.3s, ease-out).
        withAnimation(.easeOut(duration: 0.3).delay(0.7)) {
            dotOpacity = 1
            dotInScale = 1.0
        }
        // 0.9–1.5s: dot breathes once (0.6s, ease-in-out).
        withAnimation(.easeInOut(duration: 0.6).delay(0.9)) {
            dotBreathScale = 1.12
            glowOpacity = 0.55
        }
        // 1.5s: finish — fade out if ready, else show spinner + subtitle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard !finished else { return }
            finished = true
            if isReady {
                withAnimation(.easeOut(duration: 0.3)) {
                    splashOpacity = 0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    onFinished()
                }
            } else {
                withAnimation(.easeOut(duration: 0.25)) {
                    showWaiting = true
                }
            }
        }
    }
}
