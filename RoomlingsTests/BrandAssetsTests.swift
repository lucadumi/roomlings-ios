import UIKit
import XCTest

@MainActor
final class BrandAssetsTests: XCTestCase {
    func testTheBuiltAppUsesTheIconCatalogAndCompiledLaunchScreen() throws {
        let icons = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any])
        let primary = try XCTUnwrap(icons["CFBundlePrimaryIcon"] as? [String: Any])
        XCTAssertEqual(primary["CFBundleIconName"] as? String, "AppIcon")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "UILaunchStoryboardName") as? String, "LaunchScreen")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "UIUserInterfaceStyle") as? String, "Light")
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "UILaunchScreen"))
        XCTAssertNotNil(Bundle.main.url(forResource: "LaunchScreen", withExtension: "storyboardc"))
    }

    func testTheLaunchResourcesKeepOriginalColourAndAnOpaqueWhiteBackground() throws {
        let mark = try XCTUnwrap(UIImage(named: "LaunchMark", in: .main, compatibleWith: nil))
        XCTAssertEqual(mark.size, CGSize(width: 64, height: 64))
        XCTAssertEqual(mark.renderingMode, .alwaysOriginal)
        let background = try XCTUnwrap(UIColor(named: "LaunchBackground", in: .main, compatibleWith: nil))
        for style in [UIUserInterfaceStyle.light, .dark] {
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            XCTAssertTrue(background.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
                .getRed(&red, green: &green, blue: &blue, alpha: &alpha))
            for component in [red, green, blue, alpha] { XCTAssertEqual(component, 1, accuracy: 0.0001) }
        }
    }

    func testTheLaunchMarkStaysSmallAndCentredInBothOrientations() throws {
        let storyboard = UIStoryboard(name: "LaunchScreen", bundle: .main)
        let controller = try XCTUnwrap(storyboard.instantiateInitialViewController())
        controller.loadViewIfNeeded()
        let view = try XCTUnwrap(controller.view)
        let mark = try XCTUnwrap(view.subviews.compactMap { $0 as? UIImageView }.first)
        XCTAssertEqual(view.subviews.count, 1, "The approved launch screen contains only the existing mark.")
        XCTAssertEqual(mark.contentMode, .scaleAspectFit)
        XCTAssertFalse(mark.isUserInteractionEnabled)
        for size in [
            CGSize(width: 402, height: 874), CGSize(width: 874, height: 402),
            CGSize(width: 834, height: 1194), CGSize(width: 1194, height: 834)
        ] {
            view.frame = CGRect(origin: .zero, size: size)
            view.setNeedsLayout()
            view.layoutIfNeeded()
            XCTAssertEqual(mark.frame.width, 64, accuracy: 0.5)
            XCTAssertEqual(mark.frame.height, 64, accuracy: 0.5)
            XCTAssertEqual(mark.frame.midX, size.width / 2, accuracy: 0.5)
            XCTAssertEqual(mark.frame.midY, size.height / 2, accuracy: 0.5)
            let image = UIGraphicsImageRenderer(size: size).image { context in
                view.layer.render(in: context.cgContext)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "Compiled launch screen \(Int(size.width))x\(Int(size.height))"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
