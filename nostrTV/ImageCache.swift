//
//  ImageCache.swift
//  nostrTV
//
//  Created by Claude on Stream Categorization
//

import Foundation
import UIKit
import SwiftUI

actor ImageCache {
    static let shared = ImageCache()

    private var cache = NSCache<NSString, UIImage>()
    private var loadingTasks: [String: Task<UIImage?, Never>] = [:]
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
        cache.countLimit = 100 // Limit to 100 images
        cache.totalCostLimit = 50 * 1024 * 1024 // 50MB limit
    }

    func image(for url: URL) -> UIImage? {
        return cache.object(forKey: url.absoluteString as NSString)
    }

    func setImage(_ image: UIImage, for url: URL) {
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        cache.setObject(image, forKey: url.absoluteString as NSString, cost: cost)
    }

    /// Artwork hosts sometimes return an error page, an expired thumbnail, or nothing.
    /// Try the remaining advertised images before settling on the placeholder.
    func loadImage(from urls: [URL]) async -> UIImage? {
        for url in urls {
            guard !Task.isCancelled else { return nil }
            if let image = await loadImage(from: url) { return image }
        }
        return nil
    }

    func loadImage(from url: URL) async -> UIImage? {
        let urlString = url.absoluteString

        // Check if image is already cached
        if let cachedImage = cache.object(forKey: urlString as NSString) {
            return cachedImage
        }

        // Check if there's already a loading task for this URL
        if let existingTask = loadingTasks[urlString] {
            return await existingTask.value
        }

        // Create new loading task
        let task = Task<UIImage?, Never> {
            do {
                let request = URLRequest(url: url, timeoutInterval: 10)
                let (data, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse,
                      (200..<300).contains(response.statusCode) else { return nil }
                if let image = UIImage(data: data) {
                    self.setImage(image, for: url)
                    return image
                }
            } catch {
                print("\u{26A0}\u{FE0F} ImageCache: Failed to load image: \(error.localizedDescription)")
            }
            return nil
        }

        loadingTasks[urlString] = task
        let result = await task.value
        loadingTasks.removeValue(forKey: urlString)

        return result
    }
}

struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    let urls: [URL]
    let preserveImageFor: String?
    let content: (Image) -> Content
    let placeholder: () -> Placeholder

    @State private var image: UIImage?
    @State private var loadedURLs: [URL] = []
    @State private var imageOwner: String?

    init(
        url: URL?,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.urls = url.map { [$0] } ?? []
        self.preserveImageFor = nil
        self.content = content
        self.placeholder = placeholder
    }

    init(
        urls: [URL],
        preserveImageFor: String? = nil,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.urls = urls
        self.preserveImageFor = preserveImageFor
        self.content = content
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let image, loadedURLs == urls || (preserveImageFor != nil && imageOwner == preserveImageFor) {
                content(Image(uiImage: image))
            } else {
                placeholder()
            }
        }
        .task(id: CachedImageRequest(urls: urls, owner: preserveImageFor)) {
            let loaded = await ImageCache.shared.loadImage(from: urls)
            // A recycled row's cancelled task must never replace its new artwork.
            guard !Task.isCancelled else { return }
            // Live thumb URLs rotate. Keep a previous frame for the same stream
            // while refreshing, but never keep another row's artwork.
            if loaded != nil || preserveImageFor == nil || imageOwner != preserveImageFor {
                image = loaded
            }
            loadedURLs = urls
            imageOwner = preserveImageFor
        }
    }
}

private struct CachedImageRequest: Hashable {
    let urls: [URL]
    let owner: String?
}

enum ArtworkSource {
    static func urls(_ values: [String?]) -> [URL] {
        var seen = Set<URL>()
        return values.compactMap { value in
            guard let value, let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
                  ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, !host.isEmpty, seen.insert(url).inserted else { return nil }
            return url
        }
    }
}
