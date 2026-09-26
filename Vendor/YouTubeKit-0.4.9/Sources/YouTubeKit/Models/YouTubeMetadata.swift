//
//  YouTubeMetadata.swift
//  YouTubeKit
//
//  Created by Alexander Eichhorn on 04.09.21.
//

import Foundation

/// Represents metadata for a YouTube video.
public struct YouTubeMetadata: Sendable {
    
    /// The title of the YouTube video.
    public let title: String

    /// Duration reported by YouTube, in seconds. May be absent for live videos.
    public let duration: TimeInterval?

    /// The description of the YouTube video.
    public let description: String

    /// The thumbnail image of the YouTube video, if available.
    public let thumbnail: Thumbnail?

    /// Represents a YouTube video thumbnail.
    public struct Thumbnail: Sendable {
        /// The URL of the thumbnail image.
        public let url: URL
    }

    /// Initialize YouTubeMetadata from video details.
    ///
    /// - Parameters:
    ///   - videoDetails: The video details from InnerTube.VideoInfo.VideoDetails.
    /// - Returns: A YouTubeMetadata instance.
    @available(iOS 13.0, watchOS 6.0, tvOS 13.0, macOS 10.15, *)
    static func metadata(from videoDetails: InnerTube.VideoInfo.VideoDetails) -> Self {
        YouTubeMetadata(
            title: videoDetails.title ?? "",
            duration: videoDetails.lengthSeconds.flatMap(TimeInterval.init),
            description: videoDetails.shortDescription ?? "",
            thumbnail: videoDetails.thumbnail.thumbnails.map { YouTubeMetadata.Thumbnail(url: $0.url) }.last
        )
    }
    
    /// Initialize YouTubeMetadata from multiple video details - choosing the first available information each.
    ///
    /// - Parameters:
    ///   - videoDetails: The video details from InnerTube.VideoInfo.VideoDetails.
    /// - Returns: A YouTubeMetadata instance.
    @available(iOS 13.0, watchOS 6.0, tvOS 13.0, macOS 10.15, *)
    static func metadata(from videoDetails: [InnerTube.VideoInfo.VideoDetails]) -> Self? {
        guard let title = videoDetails.lazy.compactMap({ $0.title }).first else { return nil }
        
        return YouTubeMetadata(
            title: title,
            duration: videoDetails.lazy.compactMap { $0.lengthSeconds.flatMap(TimeInterval.init) }.first,
            description: videoDetails.lazy.compactMap { $0.shortDescription }.first ?? "",
            thumbnail: videoDetails.first(where: { !$0.thumbnail.thumbnails.isEmpty })?.thumbnail.thumbnails.map { YouTubeMetadata.Thumbnail(url: $0.url) }.last
        )
    }
    
}
