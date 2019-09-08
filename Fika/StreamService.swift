import Crashlytics
import UIKit

/// A callback that can be used to know when an operation as completed. Events are the preferred way to monitor state changes, however.
typealias StreamServiceCallback = (_ error: Error?) -> Void

class StreamService {
    typealias StreamsDiff = OrderedDictionary<Int64, Stream>.Difference
    typealias ChunksDiff = OrderedDictionary<Int64, Stream>.Difference

    static let instance = StreamService()

    var maxChunkAge: TimeInterval {
        return TimeInterval(7 * 86400)
    }

    /// The number of unplayed streams.
    var unplayedCount = -1 {
        didSet {
            UIApplication.shared.applicationIconBadgeNumber = self.unplayedCount
            self.unplayedCountChanged.emit()
        }
    }

    /// The current version of the cached stream data.
    static let cacheVersion = 12

    /// Triggers whenever anything changes (either single streams or the entire list of streams).
    let changed = Event<Void>()
    /// Triggers whenever the total number of chunks has changed
    let chunksChanged = Event<(newChunks: [Chunk], diff: ChunksDiff)>()
    /// Triggers whenever the set of active streams changes.
    let activeStreamsChanged = Event<(newActiveStreams: [Stream], diff: StreamsDiff)>()
    /// Triggers whenever the order of the recent streams changes.
    let recentStreamsChanged = Event<(newStreams: [Stream], diff: StreamsDiff)>()
    /// The `sentChunk` event is posted whenever a chunk is sent.
    /// The event value is the stream that the chunk was sent to and the related chunk token.
    let sentChunk = Event<(stream: Stream, chunk: SendableChunk)>()
    let streamsEndReached = Event<Void>()
    /// Trigges whenever the number of unplayed streams changes
    let unplayedCountChanged = Event<Void>()

    // TODO: Consider removing this property to reduce calculations every update.
    private(set) var chunks = OrderedDictionary<Int64, Chunk>() {
        didSet {
            let diff = oldValue.diff(self.chunks)
            guard !diff.deleted.isEmpty || !diff.inserted.isEmpty || !diff.moved.isEmpty else {
                // The list of chunks didn't change
                return
            }
            self.chunksChanged.emit(newChunks: self.chunks.values, diff: diff)
        }
    }

    // TODO: Consider removing this property to reduce calculations every update.
    private(set) var activeStreams = OrderedDictionary<Int64, Stream>() {
        didSet {
            let diff = oldValue.diff(self.activeStreams)
            guard !diff.deleted.isEmpty || !diff.inserted.isEmpty || !diff.moved.isEmpty else {
                // The list of chunks didn't change
                return
            }
            self.activeStreamsChanged.emit(newActiveStreams: self.activeStreams.values, diff: diff)
        }
    }

    /// All the recent streams for the current user.
    private(set) var streams = OrderedDictionary<Int64, Stream>() {
        didSet {
            self.saveToCache()

            let streams = self.streams
            self.unplayedCount = streams.values.reduce(0, { $0 + ($1.isUnplayed ? 1 : 0) })

            // TODO: Consider removing activeStreams logic to speed up app.
            var activeStreams = OrderedDictionary<Int64, Stream>()
            for (_, stream) in streams {
                stream.preCacheImage()
                // Consider the stream active if it has chunks.
                guard !stream.chunks.isEmpty else {
                    continue
                }
                if stream.isExternalShare {
                    // Shared stream always comes first.
                    activeStreams.insert((stream.id, stream), at: 0)
                } else {
                    activeStreams.append((stream.id, stream))
                }
            }
            self.activeStreams = activeStreams

            // Emit that something changed.
            self.changed.emit()

            // TODO: Consider removing this logic to speed up app.
            // TODO: Include "PlayableChunk" objects that have not yet been uploaded.
            self.chunks = OrderedDictionary(
                self.streams.flatMap {
                    $0.value.chunks.filter { $0 is Chunk }
                    }.sorted { first, second in
                        return first.start > second.start
                    }.map {
                        let chunk = $0 as! Chunk
                        return (chunk.id, chunk)
            })

            // Calculate a difference and potentially notify interested parties.
            let diff = oldValue.diff(self.streams)
            guard !diff.deleted.isEmpty || !diff.inserted.isEmpty || !diff.moved.isEmpty else {
                // The list of streams didn't change (note that individual streams may still have changed).
                return
            }
            self.recentStreamsChanged.emit(newStreams: self.streams.values, diff: diff)
        }
    }

    var nextPageCursor: String? {
        didSet {
            if self.nextPageCursor == nil {
                self.streamsEndReached.emit()
            }
        }
    }

    func setAttachment(streamId: Int64, attachmentId: String, attachment: Attachment?) {
        let handleResult: (IntentResult) -> Void = { result in
            guard result.successful else {
                NSLog("%@", "WARNING: Failed to add attachment: \(String(describing: result.error))")
                return
            }
            self.updateWithStreamData(data: result.data!)
        }

        if let attachment = attachment {
            Intent.addAttachment(streamId: streamId, attachmentId: attachmentId, attachment: attachment).perform(BackendClient.instance) { result in
                handleResult(result)
            }
        } else {
            Intent.removeAttachment(streamId: streamId, attachmentId: attachmentId).perform(BackendClient.instance) { result in
                handleResult(result)
            }
        }

        guard let stream = self.streams[streamId] else {
            return
        }

        stream.attachments[attachmentId] = attachment
        stream.changed.emit()
    }

    func addParticipants(streamId: Int64, participants: [Intent.Participant], callback: StreamServiceCallback? = nil) {
        Intent.addParticipants(streamId: streamId, participants: participants).perform(self.client) { result in
            guard result.successful, let data = result.data else {
                callback?(result.error)
                return
            }
            self.updateWithStreamData(data: data)
            callback?(nil)
        }
    }

    /// Creates a stream with the given participants, title, and image.
    func createStream(participants: [Intent.Participant] = [], title: String? = nil, image: Intent.Image? = nil, callback: @escaping (_ stream: Stream?, _ error: Error?) -> Void) {
        Intent.createStream(participants: participants, title: title, image: image).perform(self.client) {
            var stream: Stream?
            if $0.successful {
                stream = self.updateWithStreamData(data: $0.data!)
                self.includeStreamInRecents(stream: stream!)
                AppDelegate.userSelectedStream.emit(stream!)
            }
            callback(stream, $0.error)
        }
    }

    /// Searches for a stream with the current user and the provided participants. This is an asynchronous operation, so a callback is needed.
    func getOrCreateStream(participants: [Intent.Participant], showInRecents: Bool = false, title: String? = nil, callback: @escaping (_ stream: Stream?, _ error: Error?) -> Void) {
        if let title = title {
            self.createStream(participants: participants, title: title, image: nil, callback: callback)
            return
        }
        let solo = participants.count == 0 || (participants.count == 1 && participants.first!.identifiers.contains(where: { $0.identifier == BackendClient.instance.session?.id.description}))
        // TODO: Creating streams in this case is bad. We need the backend to support just searching.
        Intent.getOrCreateStream(participants: participants, showInRecents: showInRecents, solo: solo).perform(self.client) {
            var stream: Stream?
            if $0.successful {
                stream = self.updateWithStreamData(data: $0.data!)
                if showInRecents {
                    self.includeStreamInRecents(stream: stream!)
                }
            }

            callback(stream, $0.error)
        }
    }

    func getStream(by serviceIdentifier: ServiceIdentifier, callback: @escaping (_ stream: Stream?, _ error: Error?) -> Void) {
        // First check if we already have the stream locally.
        if let stream = self.streams.values.first(where: { $0.serviceContentId == serviceIdentifier }) {
            callback(stream, nil)
            return
        }
        self.joinStream(serviceIdentifier: serviceIdentifier, autocreate: false, callback: callback)
    }

    func loadStreamChunks(for streamId: Int64) {
        Intent.getStreamChunks(streamId: streamId).perform(BackendClient.instance) {
            guard let chunkData = $0.data?["data"] as? [[String: Any]], $0.error == nil else {
                return
            }
            let data: [String: Any] = ["id": NSNumber(value: streamId), "chunks": chunkData]
            self.updateWithStreamData(data: data)
        }
    }

    /// Joins a stream with the given invite token.
    func joinStream(serviceIdentifier: ServiceIdentifier, autocreate: Bool = true, callback: @escaping (_ stream: Stream?, _ error: Error?) -> Void) {
        Intent.joinServiceGroup(identifier: serviceIdentifier, autocreate: autocreate).perform(BackendClient.instance) { result in
            guard result.successful, let data = result.data, let stream = self.updateWithStreamData(data: data) else {
                callback(nil, result.error)
                return
            }
            self.includeStreamInRecents(stream: stream)
            callback(stream, result.error)
        }
    }

    func leaveStream(streamId: Int64, callback: StreamServiceCallback? = nil) {
        Intent.leaveStream(streamId: streamId).perform(BackendClient.instance)
        if let stream = self.streams[streamId] {
            self.removeStreamFromRecents(stream: stream)
        }
    }

    /// Remove a stream from the main conversations list.
    func removeStreamFromRecents(stream: Stream) {
        var streams = self.streams
        streams.removeValue(forKey: stream.id)
        self.streams = streams
    }

    /// Ensures that the stream is in the recent streams list.
    func includeStreamInRecents(stream: Stream) {
        if self.streams[stream.id] != nil {
            return
        }
        self.streams.append((stream.id, stream))
        self.updateStreamOrder()
    }

    /// Loads the next page of streams, if there is a "next page" cursor.
    func loadNextPage(callback: StreamServiceCallback? = nil) {
        Intent.getStreams(cursor: self.nextPageCursor).perform(self.client) {
            guard $0.successful else {
                callback?($0.error)
                return
            }
            let data = $0.data!
            self.setStreamsWithDataList(list: data["data"] as! [DataType])
            self.nextPageCursor = data["cursor"] as? String
            callback?(nil)
        }
    }

    /// Requests an update of the list of recent streams.
    func loadStreams(callback: StreamServiceCallback? = nil) {
        Intent.getStreams(cursor: nil).perform(self.client) {
            guard $0.successful else {
                callback?($0.error)
                return
            }
            let data = $0.data!
            self.setStreamsWithDataList(list: $0.data!["data"] as! [DataType], purge: true)
            if self.nextPageCursor == nil {
                self.nextPageCursor = data["cursor"] as? String
            }
            callback?(nil)
        }
    }

    /// Loads the streams from a local cache file for the current session.
    func loadFromCache() {
        guard let cachePath = self.cachePath else {
            return
        }
        if !FileManager.default.fileExists(atPath: cachePath) {
            return
        }
        #if DEBUG
        NSLog("Loading StreamService cache from disk.")
        #endif
        guard let cache = NSKeyedUnarchiver.unarchiveObject(withFile: cachePath) as? [String: Any] else {
            return
        }
        guard let version = cache["version"] as? Int, version == StreamService.cacheVersion else {
            try! FileManager.default.removeItem(atPath: cachePath)
            return
        }
        if let streamsData = cache["streams"] as? [DataType] {
            let streamsList = streamsData.flatMap { self.updateWithStreamData(data: $0) }
            self.streams = OrderedDictionary(streamsList.map { ($0.id, $0) })
        }
    }

    /// Reports the current user's interaction status with a stream.
    func reportStatus(stream: Stream, status: ActivityStatus, estimatedDuration: Int? = nil, callback: StreamServiceCallback? = nil) {
        Intent.setStreamStatus(streamId: stream.id, status: status.rawValue, estimatedDuration: estimatedDuration).perform(self.client) {
            callback?($0.error)
        }
    }

    /// Sends the newly recorded chunk to the backend + cache and update related properties.
    func sendChunk(streamId: Int64, chunk: SendableChunk, persist: Bool? = nil, showInRecents: Bool? = nil, duplicate: Bool = false, callback: StreamServiceCallback? = nil) {
        let intent = Intent.sendChunk(
            streamId: streamId,
            chunk: chunk,
            persist: persist,
            showInRecents: showInRecents,
            duplicate: duplicate)
        let start = Date().timeIntervalSince1970
        Answers.logCustomEvent(withName: "Upload Started", customAttributes: [
            "ChunkDuration": Double(chunk.duration) / 1000,
        ])
        intent.perform(self.client) { result in
            defer {
                callback?(result.error)
            }

            let duration = Date().timeIntervalSince1970 - start
            guard let data = result.data, result.successful else {
                Answers.logCustomEvent(withName: "Upload Failed", customAttributes: [
                    "RequestDuration": duration,
                ])
                return
            }

            var attributes: [String: Any] = ["RequestDuration": duration]
            if let size = chunk.url.fileSize {
                attributes["AverageBytesPerSec"] = Double(size) / duration
                attributes["FileSizeMB"] = Double(size) / 1024 / 1024
            }
            Answers.logCustomEvent(withName: "Upload Completed", customAttributes: attributes)

            // Cache this chunk so we do not re-download it.
            // TODO: Come up with a cleaner way of doing this.
            if let chunkData = (data["chunks"] as? [[String: Any]])?.last {
                let sentChunk = Chunk(streamId: streamId, data: chunkData)
                do {
                    try FileManager.default.copyItem(at: chunk.url, to: CacheService.instance.getLocalURL(sentChunk.url))
                } catch {
                    NSLog("Failed to move local chunk for remote path: \(error.localizedDescription)")
                }
            }
            self.updateWithStreamData(data: data)
        }
        // Simulate the update locally.
        self.performBatchUpdates {
            // Unset others' played state in anticipation of the backend response and push the end of the stream forward to include the new chunk.
            let newData: DataType = [
                "id": NSNumber(value: streamId),
                "last_interaction": NSNumber(value: Int64(Date().timeIntervalSince1970) * 1000),
            ]
            if let stream = self.updateWithStreamData(data: newData) {
                if showInRecents != false {
                    // Make sure the stream is included in the recents list.
                    self.includeStreamInRecents(stream: stream)
                }
                self.sentChunk.emit((stream, chunk))
            }
        }
    }

    /// Sends the given chunk to each given streams and user
    func broadcastChunk(_ chunk: SendableChunk, streams: [Stream], participants: [Participant]) {
        streams.forEach {
            self.sendChunk(streamId: $0.id, chunk: chunk, duplicate: true)
        }
        participants.forEach {
            let participant = Intent.Participant(accountId: $0.id)
            self.getOrCreateStream(participants: [participant]) { stream, error in
                guard let stream = stream, error == nil else {
                    return
                }
                stream.sendChunk(chunk)
            }
        }
    }

    func removeParticipants(streamId: Int64, participants: [Intent.Participant], callback: StreamServiceCallback? = nil) {
        Intent.removeParticipants(streamId: streamId, participants: participants).perform(BackendClient.instance) { result in
            guard result.successful, let data = result.data else {
                callback?(result.error)
                return
            }
            self.updateWithStreamData(data: data)
            callback?(nil)
        }
    }

    func setChunkReaction(chunk: Chunk, reaction: String?) {
        if let stream = self.streams[chunk.streamId],
            let chunks = stream.data["chunks"] as? [[String: Any]],
            var chunkData = chunks.first(where: { ($0["id"] as! NSNumber).int64Value == chunk.id }) {
            var reactions = chunkData["reactions"] as? [String: String] ?? [String: String]()
            reactions[BackendClient.instance.session!.id.description] = reaction
            chunkData["reactions"] = reactions
            _ = self.updateWithStreamChunkData(id: stream.id, chunkData: chunkData)
        }
        Intent.setChunkReaction(streamId: chunk.streamId, chunkId: chunk.id, reaction: reaction).perform(BackendClient.instance)
    }

    func setImage(stream: Stream, image: Intent.Image?, callback: StreamServiceCallback? = nil) {
        Intent.changeStreamImage(streamId: stream.id, image: image).perform(self.client) {
            if $0.successful {
                self.updateWithStreamData(data: $0.data!)
            }
            callback?($0.error)
        }
    }

    func setTitle(stream: Stream, title: String?) {
        Intent.changeStreamTitle(streamId: stream.id, title: title).perform(BackendClient.instance) {
            guard $0.successful else {
                NSLog("%@", "WARNING: Failed to change stream title: \(String(describing: $0.error))")
                return
            }
            self.updateWithStreamData(data: $0.data!)
        }
    }

    func setShareable(stream: Stream, shareable: Bool, callback: StreamServiceCallback? = nil) {
        Intent.changeStreamShareable(id: stream.id, shareable: true).perform(BackendClient.instance) {
            guard $0.successful else {
                NSLog("%@", "WARNING: Failed to set shareable: \(String(describing: $0.error))")
                callback?($0.error)
                return
            }
            self.updateWithStreamData(data: $0.data!)
            callback?(nil)
        }
    }

    /// Updates the backend and the cache with the new "played until" property for the specified stream.
    func setPlayedUntil(stream: Stream, playedUntil: Int64, callback: StreamServiceCallback? = nil) {
        if playedUntil > stream.playedUntil {
            // Update the "played until" value in memory if it's greater than the current one.
            stream.addStreamData([
                "last_played_from": NSNumber(value: stream.playedUntil),
                "played_until": NSNumber(value: playedUntil),
            ])
        }
        Intent.setPlayedUntil(streamId: stream.id, playedUntil: playedUntil).perform(self.client) {
            if $0.successful {
                self.updateWithStreamData(data: $0.data!)
            }
            callback?($0.error)
        }
    }

    /// Takes a list of stream JSON data objects and replaces the in-memory stream list.
    /// The "purge" flag specifies whether local streams NOT returned by this request are omitted.
    /// Purge applies only to the first 10 streams.
    func setStreamsWithDataList(list: [DataType], purge: Bool = false) {
        self.performBatchUpdates {
            var newStreams = OrderedDictionary<Int64, Stream>()
            for data in list {
                guard let stream = self.updateWithStreamData(data: data) else {
                    continue
                }
                newStreams.append((stream.id, stream))
            }
            // Merge local and server streams lists.
            for (id, stream) in self.streams.dropFirst(purge ? 10 : 0) {
                if !newStreams.keys.contains(id) {
                    newStreams.append((id, stream))
                }
            }
            self.streams = self.sortStreamsList(list: newStreams)
        }
    }

    /// Tries to look up the stream with the specified id and add the provided chunk data to it.
    func updateWithStreamChunkData(id: Int64, chunkData: DataType) -> Stream? {
        guard let stream = self.streamsLookup.object(forKey: NSNumber(value: id)) else {
            return nil
        }
        stream.addChunkData(chunkData)
        if self.streams[id] != nil {
            self.updateStreamOrder()
        }
        return stream
    }

    /// Takes a dictionary for stream JSON data and updates or creates the in-memory stream.
    @discardableResult
    func updateWithStreamData(data: DataType) -> Stream? {
        // Get and update an existing instance of the stream or create one if it doesn't exist.
        // TODO: Try to ensure we don't need the if/else below.
        let id: Int64, boxedId: NSNumber
        if let value = data["id"] as? Int64 {
            id = value
            boxedId = NSNumber(value: id)
        } else {
            boxedId = data["id"] as! NSNumber
            id = boxedId.int64Value
        }

        if let stream = self.streamsLookup.object(forKey: boxedId) {
            stream.addStreamData(data)
            if self.streams[id] != nil {
                // Reorder the recent streams list if it contains the stream that was updated.
                self.updateStreamOrder()
            }
            return stream
        }
        // Create the stream object and add it to the lookup map before returning it.
        guard let stream = Stream(data: data) else {
            return nil
        }
        self.streamsLookup.setObject(stream, forKey: boxedId)
        return stream
    }

    // MARK: - Private

    private let client: BackendClient
    private var batchUpdates = Int32(0)

    /// A weak map of stream ids to stream objects that are still retained in memory.
    private var streamsLookup = NSMapTable<NSNumber, Stream>.strongToWeakObjects()

    /// The path where the in-memory data should be cached on disk. Only available while logged in.
    private var cachePath: String? {
        guard let accountId = self.client.session?.id else {
            return nil
        }
        let directory = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first! as NSString
        let filename = "StreamsService_\(accountId).cache"
        return directory.appendingPathComponent(filename)
    }

    private init() {
        self.client = BackendClient.instance
        self.client.loggedIn.addListener(self, method: StreamService.handleLogIn)
        self.client.loggedOut.addListener(self, method: StreamService.handleLogOut)
    }

    /// Cache streams as an array of JSON dictionaries.
    private func saveToCache() {
        // TODO: Make this method called implicitly after a state change instead of manually everywhere.
        // TODO: Handle batch cache operations (i.e., cache only once per 5 seconds).
        guard let cachePath = self.cachePath else {
            return
        }
        let streams = self.streams.values.prefix(50)
        let streamsData = streams.map { $0.data }
        let cache: [String: Any] = [
            "version": StreamService.cacheVersion,
            "streams": streamsData,
        ]
        #if DEBUG
        NSLog("Saving StreamService cache to disk.")
        #endif
        NSKeyedArchiver.archiveRootObject(cache, toFile: cachePath)
    }

    /// Takes a list of stream JSON data objects and returns a list of Stream objects.
    private func getStreamsListFromData(data: [DataType]) -> [Stream] {
        return data.flatMap { self.updateWithStreamData(data: $0) }
    }

    private func handleLogIn(session: Session) {
        // Use the stream data from the session to fill the streams list.
        guard let list = session.data["streams"] as? [DataType] else {
            NSLog("WARNING: Failed to get a list of stream data from session")
            self.streams = OrderedDictionary<Int64, Stream>()
            return
        }
        self.setStreamsWithDataList(list: list)
    }

    private func handleLogOut() {
        // Reset the list of streams whenever the user logs out.
        self.streams = OrderedDictionary<Int64, Stream>()
    }

    /// Used to perform multiple updates to individual streams without reordering the list every time.
    private func performBatchUpdates(closure: () -> ()) {
        OSAtomicIncrement32(&self.batchUpdates)
        closure()
        OSAtomicDecrement32(&self.batchUpdates)
        self.updateStreamOrder()
    }

    /// Updates the internal state of the stream service.
    private func updateStreamOrder() {
        if self.batchUpdates > 0 {
            return
        }
        // Create a sorted copy of the streams list and switch to it.
        self.streams = self.sortStreamsList(list: self.streams)
    }

    // TODO: Investigate how to make this an extension on OrderedDictionary<Int64, Stream>
    private func sortStreamsList(list: OrderedDictionary<Int64, Stream>) -> OrderedDictionary<Int64,Stream> {
        let sorted = list.sorted {
            return $0.value.lastInteractionTime > $1.value.lastInteractionTime
        }
        return OrderedDictionary(sorted)
    }
}
