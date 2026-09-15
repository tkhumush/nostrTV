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

    private init() {
        cache.countLimit = 100 // Limit to 100 images
        cache.totalCostLimit = 50 * 1024 * 1024 // 50MB limit
    }

    func image(for url: URL) -> UIImage? {
        return cache.object(forKey: url.absoluteString as NSString)
    }

    func setImage(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: url.absoluteString as NSString)
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
                let (data, _) = try await URLSession.shared.data(from: url)
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
    let url: URL?
    let content: (Image) -> Content
    let placeholder: () -> Placeholder

    @State private var image: UIImage?
    @State private var isLoading = false

    /// URL of the most recently started load.
    ///
    /// Must be `@State` rather than a plain capture: a `Task` closes over a copy of
    /// this struct, so by the time it finishes `self.url` still holds whatever it was
    /// when the task started. `@State` reads through shared storage, so it reflects
    /// the value now, which is what tells us whether the result is still wanted.
    @State private var loadingURL: URL?

    init(
        url: URL?,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.content = content
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let image = image {
                content(Image(uiImage: image))
            } else {
                placeholder()
            }
        }
        .onAppear {
            loadImageIfNeeded()
        }
        .onChange(of: url) { oldURL, newURL in
            // Clear the old image when URL changes
            if oldURL != newURL {
                image = nil
                isLoading = false
                loadingURL = nil
            }
            loadImageIfNeeded()
        }
    }

    private func loadImageIfNeeded() {
        guard let url = url, image == nil, !isLoading else { return }

        isLoading = true
        loadingURL = url

        Task {
            // `loadImage` already returns the cached image when there is one, so the
            // separate cache probe that used to run first only duplicated this path —
            // and duplicated the clobbering bug below along with it.
            let loadedImage = await ImageCache.shared.loadImage(from: url)

            await MainActor.run {
                // Drop results for a URL we are no longer showing. Rows are recycled
                // as the stream list updates, so a slow load for the previous row
                // could otherwise finish last and overwrite the current image — or,
                // on failure, overwrite it with nil and leave the row blank with
                // nothing scheduled to retry.
                guard loadingURL == url else { return }

                // Never let a failed load erase what is already on screen.
                if let loadedImage {
                    image = loadedImage
                }
                isLoading = false
            }
        }
    }
}