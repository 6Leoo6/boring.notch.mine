//
//  Image2Color.swift
//  boringNotch
//
//  Created by Richard Kunkli on 07/08/2024.
//

import SwiftUI
import AppKit
import Cocoa
import Foundation
import CoreImage
import CoreGraphics
import CoreImage.CIFilterBuiltins

extension NSImage {

    
    func averageColor(completion: @escaping (NSColor?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                DispatchQueue.main.async {
                    completion(nil)
                }
                return
            }
            
            let width = cgImage.width
            let height = cgImage.height
            let totalPixels = width * height
            
            guard let context = CGContext(data: nil,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                DispatchQueue.main.async {
                    completion(nil)
                }
                return
            }
            
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            
            guard let data = context.data else {
                DispatchQueue.main.async {
                    completion(nil)
                }
                return
            }
            
            let pointer = data.bindMemory(to: UInt32.self, capacity: totalPixels)
            
            var totalRed: UInt64 = 0
            var totalGreen: UInt64 = 0
            var totalBlue: UInt64 = 0
            
            for i in 0..<totalPixels {
                let color = pointer[i]
                totalRed += UInt64(color & 0xFF)
                totalGreen += UInt64((color >> 8) & 0xFF)
                totalBlue += UInt64((color >> 16) & 0xFF)
            }
            
            let averageRed = CGFloat(totalRed) / CGFloat(totalPixels) / 255.0
            let averageGreen = CGFloat(totalGreen) / CGFloat(totalPixels) / 255.0
            let averageBlue = CGFloat(totalBlue) / CGFloat(totalPixels) / 255.0
            
            let minBrightness: CGFloat = 0.5
            let isNearBlack = averageRed < 0.03 && averageGreen < 0.03 && averageBlue < 0.03
            
            var finalColor: NSColor
            
            if isNearBlack {
                // If it's near black, just return a gray color with the minimum brightness
                finalColor = NSColor(white: minBrightness, alpha: 1.0)
            } else {
                var color = NSColor(red: averageRed, green: averageGreen, blue: averageBlue, alpha: 1.0)
                
                var hue: CGFloat = 0
                var saturation: CGFloat = 0
                var brightness: CGFloat = 0
                var alpha: CGFloat = 0
                
                color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
                
                if brightness < minBrightness {
                    // Increase brightness while maintaining hue and reducing saturation
                    let saturationScale = brightness / minBrightness
                    color = NSColor(hue: hue,
                                    saturation: saturation * saturationScale,
                                    brightness: minBrightness,
                                    alpha: alpha)
                }
                
                finalColor = color
            }
            
            DispatchQueue.main.async {
                completion(finalColor)
            }
        }
        
    }
    
    func getBrightness() -> CGFloat {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return 0
        }
        
        let inputImage = CIImage(cgImage: cgImage)
        
        let filter = CIFilter.areaAverage()
        filter.inputImage = inputImage
        filter.extent = inputImage.extent
        
        guard let outputImage = filter.outputImage else {
            return 0
        }
        
        let context = CIContext(options: nil)
        
        var bitmap = [UInt8](repeating: 0, count: 4)
        context.render(outputImage,
                       toBitmap: &bitmap,
                       rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8,
                       colorSpace: CGColorSpaceCreateDeviceRGB())
        
        let brightness = (0.2126 * CGFloat(bitmap[0]) + 0.7152 * CGFloat(bitmap[1]) + 0.0722 * CGFloat(bitmap[2])) / 255.0
        
        return brightness
    }
}

extension NSColor {
    /// Perceived brightness in sRGB, or nil when the colour has no sRGB representation.
    var srgbLuminance: CGFloat? {
        guard let rgbColor = usingColorSpace(.sRGB) else { return nil }

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        rgbColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }
}

extension Color {
    /// Album-art tint shared by the music, calendar and sneak-peek views.
    /// `avgColor` defaults to white when no artwork is loaded, so near-white input falls
    /// back instead of being dimmed into an arbitrary grey.
    static func playerTint(from color: NSColor, fallback: Color, factor: CGFloat = 0.6) -> Color {
        guard let luminance = color.srgbLuminance,
              luminance > 0.01, luminance < 0.9 else { return fallback }
        return Color(nsColor: color).ensureMinimumBrightness(factor: factor)
    }

    /// Activated counterpart to `playerTint`, for controls in their "on" state.
    /// `playerTint` normalises to `factor` luminance, so the inactive icon never
    /// exceeds it; driving this one to `targetLuminance` guarantees a fixed
    /// contrast step no matter what the artwork is. Saturation is boosted first,
    /// then the colour is blended toward white by exactly the amount needed to
    /// reach that target — a fully saturated hue like pure red is already at its
    /// brightness ceiling and cannot get there on hue alone.
    /// Artwork with no usable hue — near-white, near-black or greyscale — has no
    /// stronger version to derive, so those fall back alongside `playerTint`.
    static func playerAccent(
        from color: NSColor,
        fallback: Color,
        minimumSaturation: CGFloat = 0.12,
        targetLuminance: CGFloat = 0.85
    ) -> Color {
        guard let base = color.usingColorSpace(.sRGB),
              let luminance = color.srgbLuminance,
              luminance > 0.01, luminance < 0.9,
              base.saturationComponent >= minimumSaturation,
              let vivid = NSColor(
                  hue: base.hueComponent,
                  saturation: max(base.saturationComponent, 0.85),
                  brightness: 1,
                  alpha: 1
              ).usingColorSpace(.sRGB),
              let vividLuminance = vivid.srgbLuminance
        else { return fallback }

        let lift = vividLuminance >= targetLuminance
            ? 0
            : (targetLuminance - vividLuminance) / (1 - vividLuminance)

        return Color(
            red: Double(vivid.redComponent + (1 - vivid.redComponent) * lift),
            green: Double(vivid.greenComponent + (1 - vivid.greenComponent) * lift),
            blue: Double(vivid.blueComponent + (1 - vivid.blueComponent) * lift)
        )
    }
}

extension Color {
    func ensureMinimumBrightness(factor: CGFloat) -> Color {
        guard factor >= 0 && factor <= 1 else {
            return self // Return original color if factor is out of bounds
        }
        
        let nsColor = NSColor(self)
        
        // Convert to RGB color space
        guard let rgbColor = nsColor.usingColorSpace(.sRGB) else {
            return self // Return original color if conversion fails
        }
        
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        
        rgbColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        
        // Calculate perceived brightness using the formula: (0.299*R + 0.587*G + 0.114*B)
        let perceivedBrightness = (0.2126 * red + 0.7152 * green + 0.0722 * blue)
        
        guard perceivedBrightness > 0 else { return self }

        let scale = factor / perceivedBrightness
        red = min(red * scale, 1.0)
        green = min(green * scale, 1.0)
        blue = min(blue * scale, 1.0)
        
        return Color(red: Double(red), green: Double(green), blue: Double(blue), opacity: Double(alpha))
    }
}
