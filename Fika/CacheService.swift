import Alamofire
import AlamofireImage
import AVFoundation
import Crashlytics
import Foundation

class CacheService {
    typealias CacheCallback = (Error?) -> ()
    typealias ThumbnailCallback = (UIImage?) -> ()

    static let instance = CacheService()

    var hasPendingDownloads: Bool {
        return self.pendingDownloads.count > 0
    }

    var urlCached = Event<URL>()

    /// Requests that the specified chunk is cached locally.
    /// Callback will get `true` if/when file is available to play, `false` otherwise.
    func cache(chunk: PlayableChunk, callback: CacheCallback? = nil) {
        guard !self.hasCached(url: chunk.url) && !chunk.url.isFileURL else {
            callback?(nil)
            return
        }
        self.queue.async {
            if self.pendingDownloads[chunk.url] != nil {
                // Already logged once.
                return
            }
            Answers.logCustomEvent(withName: "Caching Started", customAttributes: [
                "ChunkAge": chunk.age,
                "OwnChunk": chunk.byCurrentUser ? "Yes" : "No",
            ])
        }
        self.cache(remoteURL: chunk.url, callback: callback)
    }

    /// Converts a potentially remote URL to what it should be for the cache.
    func getLocalURL(_ url: URL) -> URL {
        if url.scheme == "file" {
            // Don't relocate local files.
            return url
        }
        return self.cacheDirectoryURL.appendingPathComponent(url.lastPathComponent)
    }

    /// Retrieve or generate a thumbnail for the given URL.
    func getThumbnail(for chunk: PlayableChunk, callback: @escaping ThumbnailCallback) {
        let url = self.getLocalURL(chunk.url)
        let thumbnailIdentifier = url.lastPathComponent
        func done(_ image: UIImage?) {
            let callbacks = self.pendingThumbnails.removeValue(forKey: url)
            callbacks?.forEach { cb in
                DispatchQueue.main.async { cb(image) }
            }
        }
        // Make sure that the resource is available.
        CacheService.instance.cache(chunk: chunk) { error in
            self.queue.async {
                if self.pendingThumbnails[url] != nil {
                    self.pendingThumbnails[url]!.append(callback)
                    return
                } else {
                    self.pendingThumbnails[url] = [callback]
                }
                // Retrieve it from the cache if possible.
                if let thumbnail = self.thumbnailCache.image(withIdentifier: thumbnailIdentifier) {
                    done(thumbnail)
                    return
                }
                guard error == nil else {
                    done(nil)
                    return
                }
                // If the thumbnail doesn't exist, generate it now.
                let asset = AVAsset(url: url)
                // No thumbnail for audio-only content.
                guard asset.tracks(withMediaType: AVMediaTypeVideo).first != nil else {
                    done(nil)
                    return
                }
                let generator = AVAssetImageGenerator(asset: asset)
                generator.maximumSize = CGSize(width: 200, height: 200)
                let time = CMTime(seconds: 0, preferredTimescale: 1)
                do {
                    // Extract an image from the image generator.
                    let image = try generator.copyCGImage(at: time, actualTime: nil)
                    let thumbnail = UIImage(cgImage: image)
                    // Add it to the cache.
                    self.thumbnailCache.add(thumbnail, withIdentifier: thumbnailIdentifier)
                    done(thumbnail)
                } catch {
                    self.log("Failed to generate thumbnail for: \(url.path) (\(error))")
                    done(nil)
                }
            }
        }
    }

    /// Returns `true` if the URL exists cached locally on disk; otherwise, `false`.
    func hasCached(url: URL) -> Bool {
        return !self.isDownloading(url: url) && FileManager.default.fileExists(atPath: self.getLocalURL(url).path)
    }

    /// Returns `true` if the URL is in the process of being downloaded; otherwise, `false`.
    func isDownloading(url: URL) -> Bool {
        var downloading = false
        self.queue.sync {
            downloading = self.pendingDownloads[url] != nil
        }
        return downloading
    }

    // MARK: - Private

    private let autoCacheMaxAge = TimeInterval(24 * 3600)
    private let cacheDirectoryURL: URL
    private let cacheLifetime = TimeInterval(7 * 86400)
    private let queue = DispatchQueue(label: "io.fika.Fika.CacheService", qos: .userInitiated)
    private let thumbnailCache = AutoPurgingImageCache()

    private var pendingDownloads = [URL: [CacheCallback]]()
    private var pendingThumbnails = [URL: [ThumbnailCallback]]()

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.cacheDirectoryURL = caches.appendingPathComponent("MediaCache")

        // Ensure that the cache directory exists.
        let fs = FileManager.default
        if !fs.fileExists(atPath: self.cacheDirectoryURL.path) {
            try! fs.createDirectory(at: self.cacheDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        }

        // Kick off a background worker to prune the caches directory of stale files.
        DispatchQueue.global(qos: .background).async {
            self.pruneDirectory(url: self.cacheDirectoryURL)
            self.pruneDirectory(url: URL(fileURLWithPath: NSTemporaryDirectory()))
        }

        StreamService.instance.changed.addListener(self, method: CacheService.handleStreamsChanged)
    }

    private func cache(remoteURL url: URL, callback: CacheCallback? = nil) {
        // Don't "download" from the file system and avoid duplicate downloads.
        guard !self.hasCached(url: url) && !url.isFileURL else {
            callback?(nil)
            return
        }
        self.queue.async {
            if self.pendingDownloads[url] != nil {
                if let callback = callback {
                    self.pendingDownloads[url]!.append(callback)
                }
                return
            } else {
                self.pendingDownloads[url] = callback != nil ? [callback!] : []
            }
            self.log("Downloading \(url)")
            // Start a download which will move the file to the cache directory when done.
            // TODO: Verify that Alamofire uses background transfer.
            let request = Alamofire.download(url, method: .get, parameters: nil, encoding: URLEncoding.default, headers: nil, to: {
                (_, _) -> (URL, DownloadRequest.DownloadOptions) in
                // Return the path on disk where the file should be stored.
                return (self.getLocalURL(url), [])
            })
            let start = Date().timeIntervalSince1970
            request.response(completionHandler: { response in
                self.queue.async {
                    let callbacks = self.pendingDownloads.removeValue(forKey: url)
                    callbacks?.forEach { cb in
                        DispatchQueue.main.async { cb(response.error) }
                    }
                    let duration = Date().timeIntervalSince1970 - start
                    if let error = response.error {
                        self.log("Download failed: \(error) (\(url))")
                        Answers.logCustomEvent(withName: "Caching Failed", customAttributes: [
                            "RequestDuration": duration,
                        ])
                    } else {
                        self.log("Download completed: \(url)")
                        self.urlCached.emit(url)
                        var attributes: [String: Any] = ["RequestDuration": duration]
                        if let size = self.getLocalURL(url).fileSize {
                            attributes["AverageBytesPerSec"] = Double(size) / duration
                            attributes["FileSizeMB"] = Double(size) / 1024 / 1024
                        }
                        Answers.logCustomEvent(withName: "Caching Completed", customAttributes: attributes)
                    }
                }
            })
        }
    }

    private func handleStreamsChanged() {
        // Ensure that all recent chunks are cached.
        for stream in StreamService.instance.streams.values {
            for chunk in stream.chunks {
                guard !stream.isChunkPlayed(chunk) && chunk.age <= self.autoCacheMaxAge else {
                    continue
                }
                self.cache(chunk: chunk)
            }
        }
    }

    private func log(_ message: String) {
        NSLog("[CacheService] %@", message)
    }

    private func pruneDirectory(url: URL) {
        let fs = FileManager.default
        do {
            for entry in try fs.contentsOfDirectory(atPath: url.path) {
                let path = url.appendingPathComponent(entry).path
                guard let created = try? fs.attributesOfItem(atPath: path)[.creationDate] as! Date else {
                    continue
                }
                // TODO: Consider recurring files that should not be pruned.
                if Date().timeIntervalSince(created) > self.cacheLifetime {
                    self.log("Pruning: \(path) (\(created))")
                    try fs.removeItem(atPath: path)
                }
            }
        } catch {
            self.log("Failed to prune directory: \(error)")
        }
    }
}
