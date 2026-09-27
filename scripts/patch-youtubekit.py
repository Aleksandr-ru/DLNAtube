#!/usr/bin/env python3
import pathlib
import stat
import subprocess
import sys


PINNED_REVISION = "e5b7d0396ce12bf3444f0d209e8436c83373b7af"


def replace_once(text, old, new, path):
    if new in text:
        return text
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"Expected one patch point in {path}, found {count}")
    return text.replace(old, new, 1)


def patch_file(root, relative_path, replacements):
    path = root / relative_path
    original = path.read_text()
    updated = original
    for old, new in replacements:
        updated = replace_once(updated, old, new, relative_path)
    return path, original, updated


def main():
    if len(sys.argv) != 2:
        raise SystemExit("Usage: patch-youtubekit.py CHECKOUT")

    root = pathlib.Path(sys.argv[1]).resolve()
    revision = subprocess.check_output(
        ["git", "-C", str(root), "rev-parse", "HEAD"], text=True
    ).strip()
    if revision != PINNED_REVISION:
        raise SystemExit(
            "YouTubeKit patch only supports pinned revision "
            f"{PINNED_REVISION}; found {revision}"
        )

    plans = [
        patch_file(
            root,
            "Sources/YouTubeKit/YouTube.swift",
            [
                (
                    "public class YouTube {\n",
                    "public class YouTube {\n"
                    "    /// Session used for local extraction requests. Set before creating a YouTube instance.\n"
                    "    public static var networkSession: URLSession = .shared\n",
                ),
                (
                    "            request.setValue(\"en-US,en\", forHTTPHeaderField: \"accept-language\")\n"
                    "            request.httpShouldHandleCookies = false\n"
                    "            let (data, _) = try await URLSession.shared.data(for: request)\n"
                    "            _watchHTML",
                    "            request.setValue(\"en-US,en\", forHTTPHeaderField: \"accept-language\")\n"
                    "            request.httpShouldHandleCookies = false\n"
                    "            let (data, _) = try await Self.networkSession.data(for: request)\n"
                    "            _watchHTML",
                ),
                (
                    "            request.setValue(\"https://www.reddit.com/\", forHTTPHeaderField: \"Referer\")\n"
                    "            request.httpShouldHandleCookies = false\n"
                    "            let (data, _) = try await URLSession.shared.data(for: request)\n"
                    "            _embedHTML",
                    "            request.setValue(\"https://www.reddit.com/\", forHTTPHeaderField: \"Referer\")\n"
                    "            request.httpShouldHandleCookies = false\n"
                    "            let (data, _) = try await Self.networkSession.data(for: request)\n"
                    "            _embedHTML",
                ),
                (
                    "                let (data, _) = try await URLSession.shared.data(from: jsURL)\n",
                    "                let (data, _) = try await Self.networkSession.data(from: jsURL)\n",
                ),
                (
                    "            let innertubeClients: [InnerTube.ClientType] = [.visionOS, .web]\n",
                    "            // Android VR URLs reject mid-file byte ranges used by DLNA seeking.\n"
                    "            let innertubeClients: [InnerTube.ClientType] = [.visionOS, .web]\n",
                ),
            ],
        ),
        patch_file(
            root,
            "Sources/YouTubeKit/Models/YouTubeMetadata.swift",
            [
                (
                    "    public let title: String\n\n",
                    "    public let title: String\n\n"
                    "    /// Duration reported by YouTube, in seconds. May be absent for live videos.\n"
                    "    public let duration: TimeInterval?\n\n",
                ),
                (
                    "            title: videoDetails.title ?? \"\",\n",
                    "            title: videoDetails.title ?? \"\",\n"
                    "            duration: videoDetails.lengthSeconds.flatMap(TimeInterval.init),\n",
                ),
                (
                    "            title: title,\n",
                    "            title: title,\n"
                    "            duration: videoDetails.lazy.compactMap { $0.lengthSeconds.flatMap(TimeInterval.init) }.first,\n",
                ),
            ],
        ),
        patch_file(
            root,
            "Sources/YouTubeKit/InnerTube.swift",
            [
                (
                    "        let (responseData, _) = try await URLSession.shared.data(for: request)\n",
                    "        let (responseData, _) = try await YouTube.networkSession.data(for: request)\n",
                ),
                (
                    "            let videoId: String\n"
                    "            let title: String?\n"
                    "            let shortDescription: String?\n",
                    "            let videoId: String\n"
                    "            let title: String?\n"
                    "            let lengthSeconds: String?\n"
                    "            let shortDescription: String?\n",
                ),
            ],
        ),
        patch_file(
            root,
            "Sources/YouTubeKit/Remote/RemoteYouTubeClient.swift",
            [
                (
                    "        let task = URLSession.shared.webSocketTask(with: websocketRequest)\n",
                    "        // Keep remote fallback requests on the host application's configured session.\n"
                    "        let task = YouTube.networkSession.webSocketTask(with: websocketRequest)\n",
                ),
                (
                    "                    let configuration = URLSessionConfiguration.default\n",
                    "                    let configuration = YouTube.networkSession.configuration\n",
                ),
                (
                    "                    let (data, response) = try await URLSession.shared.data(for: request.urlRequest)\n",
                    "                    let (data, response) = try await YouTube.networkSession.data(for: request.urlRequest)\n",
                ),
            ],
        ),
        patch_file(
            root,
            "Sources/YouTubeKit/SignatureSolver.swift",
            [
                (
                    "            guard let url = Bundle.module.url(forResource: name, withExtension: ext) else {\n",
                    "            let appResourceURL = Bundle.main.resourceURL?\n"
                    "                .appendingPathComponent(\"YouTubeKit_YouTubeKit.bundle\")\n"
                    "                .appendingPathComponent(\"\\(name).\\(ext)\")\n"
                    "            let appURL = appResourceURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }\n"
                    "            guard let url = appURL ?? Bundle.module.url(forResource: name, withExtension: ext) else {\n",
                ),
            ],
        ),
    ]

    for path, original, updated in plans:
        if updated != original:
            path.chmod(path.stat().st_mode | stat.S_IWUSR)
            path.write_text(updated)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
