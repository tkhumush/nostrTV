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
                print("Failed to load image from \(url): \(error)")
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
        .onChange(of: url) { _, newURL in
            loadImageIfNeeded()
        }
    }

    private func loadImageIfNeeded() {
        guard let url = url, image == nil, !isLoading else { return }

        isLoading = true
        Task {
            // Check cache first
            if let cachedImage = await ImageCache.shared.image(for: url) {
                await MainActor.run {
                    self.image = cachedImage
                    self.isLoading = false
                }
                return
            }

            // Load image
            let loadedImage = await ImageCache.shared.loadImage(from: url)
            await MainActor.run {
                self.image = loadedImage
                self.isLoading = false
            }
        }
    }
}