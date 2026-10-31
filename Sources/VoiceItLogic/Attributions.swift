import Foundation

public struct AttributionSection: Equatable {
    public let heading: String
    public let lines: [String]
}

/// The text of the About window's credits: what the app is, its licence, and the credit the models' and libraries' licences require.
/// The full licence texts are in THIRD_PARTY_LICENSES.md, which ships inside the app ("Licences…" in the menu).
public enum Attributions {
    public static func sections(version: String, copyrightHolder: String, year: String, repoURL: String?) -> [AttributionSection] {
        var about = [
            "Version \(version)",
            "Private, on-device dictation. After the one-time model download, nothing leaves your Mac.",
            "Copyright © \(year) \(copyrightHolder). Free software: you may use, study, share and change it under the terms of the GNU General Public License, version 3. It comes with no warranty.",
        ]
        if let repoURL, !repoURL.isEmpty { about.append("Source code: \(repoURL)") }
        return [
            AttributionSection(heading: AppIdentity.name, lines: about),
            AttributionSection(heading: "Speech recognition model", lines: [
                "Parakeet TDT 0.6B v2 by NVIDIA, licensed under Creative Commons Attribution 4.0 International (CC BY 4.0): https://creativecommons.org/licenses/by/4.0/",
                "Converted to Core ML by FluidInference (also CC BY 4.0). Changes: converted to Core ML format; no other modification.",
            ]),
            AttributionSection(heading: "Text cleanup model", lines: [
                "Qwen3-4B-Instruct-2507 by the Qwen Team, Alibaba Cloud, under the Apache License 2.0. 4-bit MLX conversion by mlx-community.",
            ]),
            AttributionSection(heading: "Software", lines: [
                "FluidAudio (Apache-2.0), MLX and MLX Swift, MLX Swift LM (MIT), swift-transformers, swift-huggingface and swift-jinja by Hugging Face (Apache-2.0), swift-crypto, swift-asn1, swift-collections and swift-numerics (Apache-2.0), EventSource (MIT), yyjson (MIT), fastcluster (BSD-2-Clause), fmt (MIT), JSON for Modern C++ (MIT), metal-cpp (Apache-2.0).",
                "The full licence texts are in THIRD_PARTY_LICENSES.md. Choose \"Licences…\" in the menu to open it.",
            ]),
        ]
    }
}
