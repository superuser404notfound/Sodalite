import Foundation

/// One third-party component shown on the licenses screen. Notices and
/// license texts stay English on purpose (legal texts are not translated).
struct OpenSourceComponent: Identifiable {
    let name: String
    let licenseName: String
    let url: String
    /// Component-specific copyright / linkage note shown above the license text.
    let notice: String?
    /// Bundle resource (without extension) holding the license text; nil when the notice says it all.
    let textResource: String?

    var id: String { name }
}

enum OpenSourceLicenses {
    /// Ordered by how load-bearing the component is for the app.
    static let components: [OpenSourceComponent] = [
        OpenSourceComponent(
            name: "AetherEngine",
            licenseName: "LGPL-3.0 with App Store / DRM Exception",
            url: "https://github.com/superuser404notfound/AetherEngine",
            notice: nil,
            textResource: "LicenseText-AetherEngine"
        ),
        OpenSourceComponent(
            name: "FFmpeg",
            licenseName: "LGPL-2.1-or-later",
            url: "https://github.com/superuser404notfound/FFmpegBuild",
            notice: "This software uses libraries from the FFmpeg project under the LGPL-2.1-or-later, built without GPL components and dynamically linked as embedded frameworks. The source of the exact build ships as tagged releases of FFmpegBuild (see URL above); FFmpeg itself lives at ffmpeg.org.",
            textResource: "LicenseText-LGPL-2.1"
        ),
        OpenSourceComponent(
            name: "dav1d",
            licenseName: "BSD-2-Clause",
            url: "https://code.videolan.org/videolan/dav1d",
            notice: nil,
            textResource: "LicenseText-dav1d"
        ),
        OpenSourceComponent(
            name: "zimg",
            licenseName: "WTFPL",
            url: "https://github.com/sekrit-twc/zimg",
            notice: nil,
            textResource: "LicenseText-WTFPL"
        ),
        OpenSourceComponent(
            name: "libzvbi",
            licenseName: "LGPL-2.0-or-later",
            url: "https://github.com/zapping-vbi/zvbi",
            notice: "The library sources are licensed GNU Library General Public License v2 or later (ure.c under MIT) and are consumed under the LGPL-2.1 terms below. The GPL-2 licensed files in the zvbi tree (packet-830.c, pdc.c, exp-vtx.c) are excluded from this build.",
            textResource: "LicenseText-LGPL-2.1"
        ),
        OpenSourceComponent(
            name: "libdovi (dovi_tool)",
            licenseName: "MIT",
            url: "https://github.com/quietvoid/dovi_tool",
            notice: "Copyright (c) 2025 quietvoid",
            textResource: "LicenseText-MIT"
        ),
        OpenSourceComponent(
            name: "SwiftAssRenderer",
            licenseName: "MIT",
            url: "https://github.com/mihai8804858/swift-ass-renderer",
            notice: "Copyright (c) 2024 Mihai Șeremet",
            textResource: "LicenseText-MIT"
        ),
        OpenSourceComponent(
            name: "libass",
            licenseName: "ISC",
            url: "https://github.com/libass/libass",
            notice: nil,
            textResource: "LicenseText-ISC-libass"
        ),
        OpenSourceComponent(
            name: "FriBidi",
            licenseName: "LGPL-2.1-or-later",
            url: "https://github.com/fribidi/fribidi",
            notice: "Statically linked as part of the libass bundle (swift-libass).",
            textResource: "LicenseText-LGPL-2.1"
        ),
        OpenSourceComponent(
            name: "FreeType",
            licenseName: "FreeType License (FTL)",
            url: "https://freetype.org",
            notice: "Portions of this software are copyright (c) The FreeType Project (www.freetype.org). All rights reserved. Licensed under the FreeType License; the full text ships with the FreeType distribution as FTL.TXT.",
            textResource: nil
        ),
        OpenSourceComponent(
            name: "HarfBuzz",
            licenseName: "MIT (Old MIT)",
            url: "https://github.com/harfbuzz/harfbuzz",
            notice: "Copyright (c) the HarfBuzz contributors; per-file copyright holders are listed in the COPYING file of the HarfBuzz distribution.",
            textResource: nil
        ),
        OpenSourceComponent(
            name: "SMBClient",
            licenseName: "MIT",
            url: "https://github.com/kishikawakatsumi/SMBClient",
            notice: "Copyright (c) 2024 Kishikawa Katsumi",
            textResource: "LicenseText-MIT"
        ),
        OpenSourceComponent(
            name: "Point-Free Swift packages",
            licenseName: "MIT",
            url: "https://github.com/pointfreeco",
            notice: "combine-schedulers, swift-concurrency-extras, xctest-dynamic-overlay. Copyright (c) Point-Free, Inc.",
            textResource: "LicenseText-MIT"
        ),
    ]

    static func text(for component: OpenSourceComponent) -> String? {
        guard let resource = component.textResource,
              let url = Bundle.main.url(forResource: resource, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return text
    }
}
