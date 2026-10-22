import AppKit
import CoreText
import DanteKit
import SwiftUI

// A frontend theme drawn the way an app built with it looks: its sidebar, buttons, status
// chips, font and corners, and its sign-in panel. These colours are the customer's, not
// Dante's, so they come from the theme rather than Dante's own tokens.

extension ThemeColor {
    var color: Color { Color(red: red, green: green, blue: blue) }
}

/// Registers a theme's font files for this process, once each.
@MainActor
enum ThemeFonts {
    private static var registered: Set<URL> = []

    static func register(_ theme: UITheme) {
        guard let folder = theme.folder else { return }
        let urls = theme.fontFiles.map { folder.appending(path: $0.src) }.filter { !registered.contains($0) && FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        registered.formUnion(urls)
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, false, nil)
    }

    /// The theme's font at a size, or Dante's own when it has none or it isn't installed.
    static func font(_ theme: UITheme, size: CGFloat, weight: Font.Weight = .regular) -> Font {
        register(theme)
        guard let name = theme.fontName, NSFont(name: name, size: size) != nil || NSFontManager.shared.availableMembers(ofFontFamily: name) != nil else {
            return .dante(size: size, weight: weight)
        }
        return .custom(name, size: size).weight(weight)
    }
}

/// One of a theme's pictures, or nothing.
struct ThemeAsset: View {
    let theme: UITheme
    let asset: String
    var fill = false

    var body: some View {
        if let url = theme.url(of: asset), let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: fill ? .fill : .fit)
        }
    }
}

/// The square mark on the sidebar, or the customer's initials when the theme has none.
struct ThemeMark: View {
    let theme: UITheme
    var size: CGFloat = 22

    var body: some View {
        if theme.url(of: "markReversed") != nil {
            ThemeAsset(theme: theme, asset: "markReversed").frame(width: size, height: size)
        } else {
            Text(theme.initials)
                .font(ThemeFonts.font(theme, size: size * 0.42, weight: .bold))
                .foregroundStyle((theme.color("primaryForeground") ?? ThemeColor("#ffffff")!).color)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.22).fill(Color.white.opacity(0.16)))
        }
    }
}

/// The app's shell in small: sidebar, a heading, buttons and status chips.
struct ThemeShell: View {
    let theme: UITheme
    var scale: CGFloat = 1

    private var radius: CGFloat { CGFloat(theme.radius ?? 6) * scale }
    private var primary: Color { (theme.color("primary") ?? ThemeColor("#2563eb")!).color }
    private var onPrimary: Color { (theme.color("primaryForeground") ?? ThemeColor("#ffffff")!).color }
    private var sidebar: Color { (theme.color("sidebar") ?? ThemeColor("#1f2937")!).color }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 7 * scale) {
                ThemeMark(theme: theme, size: 20 * scale).padding(.bottom, 4 * scale)
                ForEach(0..<4) { index in
                    RoundedRectangle(cornerRadius: radius * 0.6)
                        .fill(onPrimary.opacity(index == 1 ? 0.22 : 0.0))
                        .overlay(alignment: .leading) {
                            Capsule().fill(onPrimary.opacity(index == 1 ? 0.95 : 0.55)).frame(width: [30, 38, 26, 34][index] * scale, height: 3.5 * scale)
                                .padding(.leading, 6 * scale)
                        }
                        .frame(height: 13 * scale)
                }
                Spacer(minLength: 0)
            }
            .padding(9 * scale)
            .frame(width: 66 * scale)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(sidebar)
            VStack(alignment: .leading, spacing: 8 * scale) {
                Text(theme.productName ?? "Product")
                    .font(ThemeFonts.font(theme, size: 13 * scale, weight: .semibold))
                    .foregroundStyle(Color(white: 0.12))
                    .lineLimit(1)
                Text("Overview of this week")
                    .font(ThemeFonts.font(theme, size: 9 * scale))
                    .foregroundStyle(Color(white: 0.45))
                    .lineLimit(1)
                HStack(spacing: 5 * scale) {
                    Text("Save")
                        .font(ThemeFonts.font(theme, size: 9 * scale, weight: .semibold))
                        .foregroundStyle(onPrimary)
                        .padding(.horizontal, 9 * scale).padding(.vertical, 4 * scale)
                        .background(RoundedRectangle(cornerRadius: radius).fill(primary))
                    Text("Cancel")
                        .font(ThemeFonts.font(theme, size: 9 * scale, weight: .medium))
                        .foregroundStyle(primary)
                        .padding(.horizontal, 9 * scale).padding(.vertical, 4 * scale)
                        .background(RoundedRectangle(cornerRadius: radius).strokeBorder(primary, lineWidth: max(1, scale)))
                }
                HStack(spacing: 4 * scale) {
                    status("success", "Low", ThemeColor("#15803d")!)
                    status("warning", "Medium", ThemeColor("#b45309")!)
                    status("danger", "High", ThemeColor("#b91c1c")!)
                }
                RoundedRectangle(cornerRadius: radius)
                    .fill(LinearGradient(colors: [primary, (theme.color("secondary") ?? theme.color("primary") ?? ThemeColor("#2563eb")!).color],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(height: 6 * scale)
                Spacer(minLength: 0)
            }
            .padding(10 * scale)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.white)
        }
    }

    private func status(_ tone: String, _ label: String, _ fallback: ThemeColor) -> some View {
        let fg = (theme.status[tone]?["fg"] ?? fallback).color
        let bg = theme.status[tone]?["bg"]?.color ?? fg.opacity(0.12)
        return Text(label)
            .font(ThemeFonts.font(theme, size: 8 * scale, weight: .medium))
            .foregroundStyle(fg)
            .padding(.horizontal, 6 * scale).padding(.vertical, 2 * scale)
            .background(Capsule().fill(bg))
    }
}

/// The sign-in panel: the artwork or the brand gradient with the white logo, and the form.
struct ThemeSignIn: View {
    let theme: UITheme
    var scale: CGFloat = 1

    private var primary: Color { (theme.color("primary") ?? ThemeColor("#2563eb")!).color }

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                LinearGradient(colors: [primary, (theme.color("secondary") ?? theme.color("primary") ?? ThemeColor("#2563eb")!).color],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                if theme.url(of: "loginArtwork") != nil {
                    GeometryReader { proxy in
                        ThemeAsset(theme: theme, asset: "loginArtwork", fill: true)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipped()
                    }
                }
                VStack(spacing: 6 * scale) {
                    if theme.url(of: "logoReversed") != nil {
                        ThemeAsset(theme: theme, asset: "logoReversed").frame(height: CGFloat(theme.loginLogoHeight ?? 40) * 0.6 * scale)
                    } else {
                        Text(theme.customerName ?? theme.name)
                            .font(ThemeFonts.font(theme, size: 15 * scale, weight: .bold))
                            .foregroundStyle((theme.color("primaryForeground") ?? ThemeColor("#ffffff")!).color)
                    }
                    if let tagline = theme.tagline {
                        Text(tagline).font(ThemeFonts.font(theme, size: 9 * scale)).foregroundStyle(Color.white.opacity(0.85))
                    }
                }
                .padding(12 * scale)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            VStack(alignment: .leading, spacing: 7 * scale) {
                Text(theme.productName ?? "Product")
                    .font(ThemeFonts.font(theme, size: 14 * scale, weight: .semibold))
                    .foregroundStyle(Color(white: 0.12))
                field("Email")
                field("Password")
                Text("Sign in")
                    .font(ThemeFonts.font(theme, size: 9.5 * scale, weight: .semibold))
                    .foregroundStyle((theme.color("primaryForeground") ?? ThemeColor("#ffffff")!).color)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5 * scale)
                    .background(RoundedRectangle(cornerRadius: CGFloat(theme.radius ?? 6) * scale).fill((theme.color("loginCta") ?? ThemeColor("#2563eb")!).color))
                if let holder = theme.copyrightHolder {
                    Text("© \(Calendar.current.component(.year, from: Date()).formatted(.number.grouping(.never))) \(holder)")
                        .font(ThemeFonts.font(theme, size: 7.5 * scale))
                        .foregroundStyle(Color(white: 0.5))
                        .lineLimit(1)
                }
            }
            .padding(14 * scale)
            .frame(width: 170 * scale)
            .frame(maxHeight: .infinity)
            .background(Color.white)
        }
    }

    private func field(_ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2 * scale) {
            Text(label).font(ThemeFonts.font(theme, size: 7.5 * scale, weight: .medium)).foregroundStyle(Color(white: 0.4))
            RoundedRectangle(cornerRadius: CGFloat(theme.radius ?? 6) * scale)
                .strokeBorder(Color(white: 0.82), lineWidth: 1)
                .frame(height: 15 * scale)
        }
    }
}
