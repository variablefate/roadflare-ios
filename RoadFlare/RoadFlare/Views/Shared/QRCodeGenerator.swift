import SwiftUI
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Generates a colored QR code image from a string.
/// Uses CIQRCodeGenerator + CIFalseColor for custom foreground/background colors.
struct QRCodeImage {
    /// Generate a QR code UIImage with custom colors.
    /// - Parameters:
    ///   - string: The data to encode in the QR code.
    ///   - foreground: QR module color (default: orange from Kinetic Beacon palette).
    ///   - background: Background color (default: dark surface).
    ///   - size: Output image size in points.
    static func generate(
        from string: String,
        foreground: UIColor = UIColor(Color.rfPrimary),
        background: UIColor = UIColor(Color.rfSurfaceContainer),
        size: CGFloat = 280
    ) -> UIImage? {
        let context = CIContext()

        // Generate QR code
        let qrFilter = CIFilter.qrCodeGenerator()
        qrFilter.message = Data(string.utf8)
        qrFilter.correctionLevel = "M"

        guard let qrImage = qrFilter.outputImage else { return nil }

        // Apply custom colors
        let colorFilter = CIFilter.falseColor()
        colorFilter.inputImage = qrImage
        colorFilter.color0 = CIColor(color: background)  // "0" pixels (background)
        colorFilter.color1 = CIColor(color: foreground)  // "1" pixels (QR modules)

        guard let coloredImage = colorFilter.outputImage else { return nil }

        // Scale up (QR codes are tiny by default, need to scale for crisp rendering)
        let scale = size / coloredImage.extent.width
        let scaledImage = coloredImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
