![DLNAtube](./Resources/DlnaTube-128.png?raw=true)

# DLNAtube

A minimalist macOS application that plays YouTube videos on TVs and other DLNA/UPnP MediaRenderer devices.

**Русский:** Приложение поддерживает русский интерфейс. См. [README на русском языке](README.md).

![DLNAtube screenshot](./Screenshots/03.png?raw=true)

## Building and running

Requires macOS 13 or later and Xcode Command Line Tools with Swift 5.9+, `clang`, and `make`.

```sh
sh scripts/build-app.sh
open dist/DLNAtube.app
```

The `Vendor/` directory is not stored in Git. YouTubeKit 0.4.9 is a Swift package dependency. Before building, `scripts/prepare-youtubekit.sh` resolves the pinned version and applies a patch with the standard `patch` utility for proxy support, video duration, seeking, and app resources. Package sources stay under `.build/`; the patch file `scripts/youtubekit.patch` is stored in the repository. `scripts/setup-vendor.sh` downloads the FFmpeg 8.1.3 source archive into `Vendor/FFmpeg`; `scripts/build-app.sh` runs setup automatically if the archive is missing. If the project does not contain a prebuilt FFmpeg library for the current architecture, the script builds it from the archive. The first such build takes longer.

To run the tests:

```sh
sh scripts/prepare-youtubekit.sh
swift test
```

## Usage

The Mac and TV must be connected to the same local network. Allow the application to access the local network when it starts for the first time; macOS or the firewall may also ask for permission to accept incoming connections. The application automatically searches for devices at startup. If the TV does not appear, click **Find devices**.

Select a device and paste the HTTPS URL of a YouTube video. The panel below the device list shows the formats advertised in the device's DLNA profiles and the resolution information found in those profiles. This may differ from the exact maximum resolution of the TV screen.

The URL field stores up to 100 unique recently played URLs. An entry is added after playback starts successfully. Focusing an empty field shows the 10 most recent titles. As you type, the application searches titles and URLs for every non-whitespace group entered.

The application controls playback, pause, and stop. It polls the TV for playback state and position and displays them in the interface. If the TV does not report the duration, the application uses the YouTube metadata. When the application quits, it sends a stop command to the TV.

Seeking works differently depending on the stream. For MP4, the application sends a DLNA Seek command to the TV. For separate video and audio tracks, it starts a new MPEG-TS stream from the nearest keyframe, so the actual position may differ from the selected position by several seconds. On the tested Samsung UE46EH5307, seeking in such an MPEG-TS stream with the TV remote does not work.

Open Settings with the gear button or `⌘,`. You can select the Russian or English interface and configure a proxy. Before the first saved selection, the application uses Russian when Russian is the primary macOS language and English for all other languages. The default proxy is `http://localhost:10809`. Addresses using `http://`, `https://`, and `socks5://` are accepted; an empty field uses the system network settings. The proxy applies to connections from the Mac to YouTube, while the TV receives the stream from the Mac over the local network. The language and proxy are applied together after you click **Save**, and the Settings window then closes.

## Video streaming and limitations

The application uses the embedded [YouTubeKit](https://github.com/alexeichhorn/YouTubeKit) 0.4.9 library and its local extraction method to obtain stream URLs. When YouTube provides a compatible combined H.264/AAC MP4 stream, the application sends it directly to the TV with HTTP Range support. When video and audio are available separately, the application reads them in ranges and combines them into MPEG-TS with FFmpeg while streaming. The complete video is never downloaded or stored on disk, and no decoding or transcoding takes place.

The application selects the highest compatible resolution that does not exceed the limit configured for the selected device. If no lower option is available, it uses the lowest available higher resolution. The selected quality limit is stored separately for each device. Options up to 4320p (8K) are available, and only compatible H.264 video and AAC audio streams are supported. Live streams and DRM-protected videos are not supported. YouTube changes its internal API, so stream extraction may temporarily stop working until the library is updated.

Safari and WebKit are not used in the current implementation. The application obtains stream URLs through YouTubeKit and sends data to the TV through a local HTTP server.

## Embedded libraries and licenses

YouTubeKit 0.4.9 is fetched from its [upstream repository](https://github.com/alexeichhorn/YouTubeKit) as an exact Swift package version. The application uses local extraction only and does not call the library's remote service. `scripts/prepare-youtubekit.sh` applies `scripts/youtubekit.patch` with the standard `patch` utility to retain proxy settings, expose video duration, and support seeking and resource loading from the built `.app`. Package sources and build artifacts stay under ignored `.build/`; `Vendor/` is also excluded from Git.

Separate streams are combined by a locally built library based on [FFmpeg 8.1.3](https://ffmpeg.org/download.html). The build disables GPL components, command-line programs, decoding, and transcoding. The setup script downloads the source archive into `Vendor/FFmpeg`; `scripts/build-media-library.sh` builds the library. License texts are kept in `Resources/ThirdPartyLicenses` and included in the `.app` bundle. The bundle does not include the FFmpeg source archive or a standalone `ffmpeg` command.

## Local network permission and signing

By default, the application uses a local ad hoc signature. macOS may ask for Local Network permission again after the application is updated. For more stable permission handling, use an Apple Development certificate:

```sh
DLNATUBE_CODESIGN_IDENTITY="Apple Development: …" sh scripts/build-app.sh
```

---

© 2026 [Aleksandr.ru](https://aleksandr.ru)
