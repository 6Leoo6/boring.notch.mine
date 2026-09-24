//
//  MusicVisualizer.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 02/08/24.
//
import AppKit
import Cocoa
import SwiftUI

class AudioSpectrum: NSView {
    private var barLayers: [CAShapeLayer] = []
    private var barScales: [CGFloat] = []
    private var isPlaying: Bool = true
    private var isAnimating = false
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupBars()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        setupBars()
    }

    private func setupBars() {
        let barWidth: CGFloat = 2
        let barCount = 4
        let spacing: CGFloat = barWidth
        let totalWidth = CGFloat(barCount) * (barWidth + spacing)
        let totalHeight: CGFloat = 14
        frame.size = CGSize(width: totalWidth, height: totalHeight)

        for i in 0 ..< barCount {
            let xPosition = CGFloat(i) * (barWidth + spacing)
            let barLayer = CAShapeLayer()
            barLayer.frame = CGRect(x: xPosition, y: 0, width: barWidth, height: totalHeight)
            barLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            barLayer.position = CGPoint(x: xPosition + barWidth / 2, y: totalHeight / 2)
            barLayer.fillColor = NSColor.white.cgColor
            barLayer.backgroundColor = NSColor.white.cgColor
            barLayer.allowsGroupOpacity = false
            barLayer.masksToBounds = true
            let path = NSBezierPath(roundedRect: CGRect(x: 0, y: 0, width: barWidth, height: totalHeight),
                                    xRadius: barWidth / 2,
                                    yRadius: barWidth / 2)
            barLayer.path = path.cgPath
            barLayers.append(barLayer)
            barScales.append(0.35)
            layer?.addSublayer(barLayer)
        }
    }
    
    /// How long one bar holds a height before moving to the next.
    private static let stepDuration: CFTimeInterval = 0.3
    /// Random heights baked into a single repeating cycle. Long enough that the loop is not
    /// legible as a loop, short enough to stay a cheap animation to hand the render server.
    private static let stepsPerCycle = 32

    private func startAnimating() {
        guard !isAnimating else { return }
        isAnimating = true
        for (i, barLayer) in barLayers.enumerated() {
            barLayer.add(Self.makeCycle(stagger: i), forKey: "scaleY")
        }
    }

    private func stopAnimating() {
        isAnimating = false
        resetBars()
    }

    /// One long repeating keyframe cycle per bar, instead of a 0.3s `Timer` that pushed four
    /// fresh `CABasicAnimation`s on every tick.
    ///
    /// That timer cost ~3.3 wakeups per second for the entire time music was playing — to drive
    /// a decoration whose heights are random anyway, and which nobody is necessarily looking at.
    /// Baked into keyframes the render server runs the whole thing without waking this process
    /// at all, and the motion is indistinguishable.
    private static func makeCycle(stagger: Int) -> CAKeyframeAnimation {
        var values: [CGFloat] = [0.35]
        for _ in 0 ..< stepsPerCycle {
            values.append(.random(in: 0.35 ... 1.0))
        }
        // Close the loop on the value it started from, or the repeat shows a visible jump.
        values.append(0.35)

        let animation = CAKeyframeAnimation(keyPath: "transform.scale.y")
        animation.values = values
        animation.duration = stepDuration * Double(values.count - 1)
        animation.calculationMode = .linear
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        animation.fillMode = .forwards
        // Offset each bar into a different part of the cycle so they do not pulse in lockstep.
        animation.timeOffset = Double(stagger) * stepDuration * 1.7
        if #available(macOS 13.0, *) {
            animation.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 24, preferred: 24)
        }
        return animation
    }

    private func resetBars() {
        for (i, barLayer) in barLayers.enumerated() {
            barLayer.removeAllAnimations()
            barLayer.transform = CATransform3DMakeScale(1, 0.35, 1)
            barScales[i] = 0.35
        }
    }
    
    func setPlaying(_ playing: Bool) {
        isPlaying = playing
        if isPlaying {
            startAnimating()
        } else {
            stopAnimating()
        }
    }
}

struct AudioSpectrumView: NSViewRepresentable {
    @Binding var isPlaying: Bool
    
    func makeNSView(context: Context) -> AudioSpectrum {
        let spectrum = AudioSpectrum()
        spectrum.setPlaying(isPlaying)
        return spectrum
    }
    
    func updateNSView(_ nsView: AudioSpectrum, context: Context) {
        nsView.setPlaying(isPlaying)
    }
}

#Preview {
    AudioSpectrumView(isPlaying: .constant(true))
        .frame(width: 16, height: 20)
        .padding()
}
