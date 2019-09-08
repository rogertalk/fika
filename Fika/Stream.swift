import AlamofireImage
import Foundation
import AVFoundation

class Stream {
    static let externalShareTitle = "%ShareExternally%"

    /// The id that uniquely identifies this stream.
    let id: Int64

    var attachments = [String: Attachment]()

    var botParticipants: [Participant] {
        return self.otherParticipants.filter { $0.isBot }
    }

    /// An event that notifies listeners that the stream changed.
    let changed = Event<Void>()

    /// The most recent chunks in the stream.
    lazy var chunks: [PlayableChunk]! = self.allChunks.filter { $0.age < StreamService.instance.maxChunkAge }

    var unplayedChunks: [PlayableChunk] {
        var unplayed = [PlayableChunk]()
        for i in (0..<self.chunks.endIndex).reversed() {
            let chunk = self.chunks[i]
            guard !chunk.byCurrentUser else {
                continue
            }
            guard !self.isChunkPlayed(chunk) else {
                break
            }
            unplayed.insert(chunk, at: 0)
        }
        return unplayed
    }

    var currentUserDidMissSync: Bool {
        // Return true if there has been a sync in the last 3 hours.
        guard let session = BackendClient.instance.session else {
            return false
        }
        let hasRecentSync = self.meetingTimes?.contains(where: { components in
            guard let weekday = components.weekday, let hour = components.hour, let minute = components.minute else {
                return false
            }
            // Check if the sync was within the last 3 hours.
            let syncTime = hour * 60 + minute
            let now = NSDate()
            let nowTime = now.hour() * 60 + now.minute()
            let elapsed = ((nowTime + 1440) - syncTime) % 1440
            return now.weekday() == weekday && elapsed < 180
        })
        guard hasRecentSync ?? false else {
            return false
        }
        // If there was a sync, check if the current user has submitted an entry for it already.
        for i in (0..<self.chunks.endIndex).reversed() {
            let chunk = self.chunks[i]
            // Only look at chunks within the last 4 hours.
            guard Date(timeIntervalSince1970: Double(chunk.start / 1000)).timeIntervalSinceNow > -14400 else {
                return true
            }
            // If a chunk sent by the current user was found, they have not missed the sync.
            if chunk.senderId == session.id {
                return false
            }
        }
        return true
    }

    /// A custom title for the stream, if any.
    var customTitle: String? {
        return self.data["title"] as? String
    }

    /// The underlying data for this stream.
    private(set) var data: DataType {
        didSet {
            // TODO: This should probably be a little bit more intelligent.
            self.changed.emit()
        }
    }

    /// Participants that are not active on fika.io.
    var externalParticipants: [Participant] {
        return self.otherParticipants.filter { !$0.isActive }
    }

    var hasActiveParticipants: Bool {
        return self.otherParticipants.contains { $0.isActive }
    }

    /// Returns `true` if the current user was the last person to speak to this stream.
    var hasCurrentUserReplied: Bool {
        guard let lastChunk = self.chunks.last else {
            return false
        }
        return lastChunk.byCurrentUser
    }

    /// Whether the stream has a custom image set.
    var hasCustomImage: Bool {
        return (self.data["image_url"] as? String) != nil
    }

    var hasTeamMember: Bool {
        return self.otherParticipants.contains(where: { $0.commonTeams.count > 0 })
    }

    /// An image that should be shown for the stream.
    var image: UIImage? {
        // TODO: Cache all images on disk and load them as thumbnails.
        if self.cachedImage != nil {
            return self.cachedImage
        }
        guard let urlString = self.data["image_url"] as? String, let _ = URL(string: urlString) else {
            // TODO: Return an image for the URL.
            return nil
        }
        // TODO: flatMap or just map and use default for nils?
        let participantImages = self.otherParticipants.flatMap { $0.imageURL }
        if participantImages.count > 0 {
            // TODO: Return split view image.
            return nil
        }
        // TODO: Return default image.
        return nil
    }

    /// The initials of the stream title.
    var initials: String {
        return self.title.initials
    }

    var isDuo: Bool {
        return !self.isGroup && self.otherParticipants.count == 1
    }

    var isGroup: Bool {
        return self.customTitle != nil
    }

    /// Whether the stream is still in the invitation stage.
    var isInvitation: Bool {
        if self.serviceContentId != nil {
            // This stream exports content, so is not considered an invitation.
            return false
        }
        return self.otherParticipants.count == 1 && !self.hasActiveParticipants
    }

    var isExternalShare: Bool {
        return self.otherParticipants.count == 0 && self.customTitle == Stream.externalShareTitle
    }

    var isSolo: Bool {
        // TODO: This should only return true for the actual solo stream (not for groups with 0 other people).
        return !self.isGroup && self.otherParticipants.count == 0
    }

    /// Indicates whether any chunks in this stream are unplayed.
    var isUnplayed: Bool {
        return self.unplayedChunks.count > 0
    }

    /// Whether the stream should be considered visible.
    var isVisible: Bool {
        return self.data["visible"] as! Bool
    }

    /// The time when someone last posted to this stream.
    var lastChunkTime: Date? {
        guard let chunk = self.chunks.last else {
            return nil
        }
        return Date(timeIntervalSince1970: Double(chunk.end) / 1000)
    }

    /// The timestamp (in milliseconds since 1970) of the last interaction with this stream.
    var lastInteraction: Int64 {
        return (self.data["last_interaction"] as! NSNumber).int64Value
    }

    /// The time of the last interaction in a stream.
    var lastInteractionTime: Date {
        return Date(timeIntervalSince1970: Double(self.lastInteraction) / 1000)
    }

    /// The timestamp (in milliseconds since 1970) of where in the stream the user's last play session began.
    var lastPlayedFrom: Int64 {
        return (self.data["last_played_from"] as! NSNumber).int64Value
    }

    /// The times (in UTC) of the stream meetings
    var meetingTimes: [DateComponents]? {
        get {
            // TODO: Remove this migration code
            if let attachment = self.attachments["attachment0"],
                let triggersData = attachment.data["triggers"] as? String,
                let data = Data(base64Encoded: triggersData) {
                let dateComponents = NSKeyedUnarchiver.unarchiveObject(with: data) as? [DateComponents]
                self.meetingTimes = dateComponents
                Intent.removeAttachment(streamId: self.id, attachmentId: "attachment0").perform(BackendClient.instance)
                // Remove locally
                self.attachments.removeValue(forKey: "attachment0")
            }

            guard let attachment = self.attachments["sync"],
                let triggersData = attachment.data["triggers"] as? [[String: Any]] else {
                return nil
            }
            return triggersData.map({
                let hour = $0["hour"] as! Int
                let minute = $0["minute"] as! Int
                let weekday = $0["weekday"] as! Int

                let utcComponents = DateComponents(timeZone: TimeZone(abbreviation: "UTC"), year: Date().year, hour: hour, minute: minute)
                let date = Calendar.current.date(from: utcComponents)!
                // Create new components based on the current timezone
                return DateComponents(hour: date.hour, minute: date.minute, weekday: weekday)
            })
        }
        set {
            guard let triggers = newValue else {
                self.setAttachment(id: "sync", attachment: nil)
                return
            }
            let triggersData = triggers.map {
                return ["hour": $0.hour,
                        "minute": $0.minute,
                        "weekday": $0.weekday]
            }
            let data: [String: Any] = [
                "type": "sync",
                "triggers": triggersData
            ]
            self.setAttachment(id: "sync",
                               attachment: Attachment(data: data))
        }
    }

    /// The participant with the most active status. If all participants are idle, returns nil.
    var nonIdleParticipant: Participant? {
        let mostActive = self.otherParticipants.max(by: { a, b in a.activityStatus < b.activityStatus })
        guard mostActive?.activityStatus != .idle else {
            return nil
        }
        return mostActive
    }

    /// The other people in the stream.
    private(set) var otherParticipants = [Participant]()

    /// The timestamp (in milliseconds since 1970) of the time up until which the current user has played this stream.
    var playedUntil: Int64 {
        return (self.data["played_until"] as! NSNumber).int64Value
    }

    var serviceContentId: ServiceIdentifier? {
        guard let id = self.data["service_content_id"] as? String else {
            return nil
        }
        return ServiceIdentifier(value: id)
    }

    var serviceMemberCount: Int? {
        return self.data["service_member_count"] as? Int
    }

    /// A short version of the stream's title (e.g., the first name of a person).
    var shortTitle: String {
        if let title = self.customTitle {
            return title.shortName
        } else {
            return "\(self.title.shortName) + \(self.otherParticipants.count - 1)"
        }
    }

    /// The current status of the stream. For groups, this will be the most important status (recording > playing > idle).
    var status: ActivityStatus {
        return self.nonIdleParticipant?.activityStatus ?? .idle
    }

    /// The title that should be displayed for the stream.
    var title: String {
        if self.isExternalShare {
            return "Shared Videos"
        }
        
        // Return title if there is one
        if let title = self.customTitle {
            return title
        }
        // Get a list of names for all of the participants.
        let mapper: (Participant) -> String
        if self.otherParticipants.count > 1 {
            mapper = { $0.displayName.shortName }
        } else {
            mapper = { $0.displayName }
        }
        let names = self.otherParticipants.map(mapper)
        if names.isEmpty {
            if let session = BackendClient.instance.session {
                return "\(session.displayName) (you)"
            }
            return "New Conversation"
        }
        return names.joined(separator: ", ")
    }

    /// The total duration of content posted to this stream, in seconds.
    var totalDuration: TimeInterval {
        return (self.data["total_duration"] as! Double) / 1000
    }

    var transcriptionLocale: Locale {
        get {
            guard let attachment = self.attachments["transcription"], let id = attachment.data["locale"] as? String else {
                return Locale(identifier: Locale.current.identifier.replacingOccurrences(of: "_", with: "-"))
            }
            return Locale(identifier: id)
        }
        set {
            let id = newValue.identifier.replacingOccurrences(of: "_", with: "-")
            self.setAttachment(id: "transcription", attachment: Attachment(data: ["locale": id, "type": "settings"]))
        }
    }

    // MARK: - Initializers

    required init?(data: DataType) {
        self.data = data
        guard let id = (data["id"] as? NSNumber)?.int64Value else {
            self.id = -1
            return nil
        }
        self.id = id
        if data["chunks"] == nil || data["others"] == nil {
            // We can't create a new stream from the data provided.
            return nil
        }
        self.updateComputedFields()
    }

    // MARK: - Methods

    /// Adds an attachment to the stream.
    func setAttachment(id: String, attachment: Attachment?) {
        StreamService.instance.setAttachment(streamId: self.id, attachmentId: id, attachment: attachment)
    }

    /// Adds a single chunk data object to the stream.
    func addChunkData(_ chunk: DataType) {
        var newData = self.data
        if let end = chunk["end"] as? NSNumber,
            end.compare(self.data["last_interaction"] as! NSNumber) == .orderedDescending
        {
            newData["last_interaction"] = end
        }
        newData["chunks"] = mergeChunks(self.data["chunks"] as! [DataType], withChunks: [chunk])
        self.data = newData
        self.updateComputedFields(participants: false)
    }

    /// Updates the stream's data with the provided data.
    func addStreamData(_ data: DataType) {
        var newData = data
        // If the local timestamps are more recent than the new ones (because backend updates are pending), keep them.
        func maxNumberValueForKey(_ key: String, dicts: [String: Any]...) -> Any {
            return dicts.flatMap { $0[key] as? NSNumber }.max { (a, b) in a.compare(b) == .orderedAscending } ?? NSNull()
        }
        newData["last_interaction"] = maxNumberValueForKey("last_interaction", dicts: self.data, data)
        newData["last_played_from"] = maxNumberValueForKey("last_played_from", dicts: self.data, data)
        newData["played_until"] = maxNumberValueForKey("played_until", dicts: self.data, data)
        // Merge the old and new chunks.
        if let oldChunks = self.data["chunks"] as? [[String: Any]], let newChunks = data["chunks"] as? [[String: Any]] {
            newData["chunks"] = mergeChunks(oldChunks, withChunks: newChunks)
        }

        let chunksUpdated = newData["chunks"] != nil
        let participantsUpdated = newData["others"] != nil
        // Keep any fields that didn't exist in the new data (because data may be partial).
        for (key, value) in self.data {
            if newData[key] == nil {
                newData[key] = value
            }
        }
        self.data = newData
        self.updateComputedFields(chunks: chunksUpdated, participants: participantsUpdated)
    }

    func clearImage() {
        StreamService.instance.setImage(stream: self, image: nil)
    }

    func clearTitle() {
        StreamService.instance.setTitle(stream: self, title: nil)
    }

    func getParticipant(_ participantId: Int64) -> Account? {
        if let account = BackendClient.instance.session, account.id == participantId {
            return account
        }
        return self.otherParticipants.first { $0.id == participantId }
    }

    func isChunkPlayed(_ chunk: PlayableChunk) -> Bool {
        return (chunk.byCurrentUser && !self.isSolo) || self.playedUntil >= chunk.end
    }

    /// Disables push notifications for this stream.
    func mute(until: Date) {
        SettingsManager.mute(stream: self, until: until)
    }

    /// Returns the participants that played the provided chunk, including the sender and the current user.
    func participantsPlayed(chunk: PlayableChunk) -> [Account] {
        var participants = [Account]()
        let session = BackendClient.instance.session!
        if chunk.senderId == session.id {
            participants.append(session)
        } else {
            if let sender = self.otherParticipants.first(where: { $0.id == chunk.senderId }) {
                participants.append(sender)
            }
            if self.playedUntil >= chunk.end {
                participants.append(session)
            }
        }
        let played: [Account] = self.otherParticipants.filter { $0.id != chunk.senderId && $0.playedUntil >= chunk.end }
        participants.append(contentsOf: played)
        return participants
    }

    func preCacheImage() {
        // Access the image property to begin loading it.
        _ = self.image
    }

    /// Reports a status for the current user and stream, such as "playing" or "recording".
    func reportStatus(_ status: ActivityStatus, estimatedDuration: Int? = nil) {
        StreamService.instance.reportStatus(stream: self, status: status, estimatedDuration: estimatedDuration)
    }

    /// Send a chunk of audio to the other participants in the stream.
    func sendChunk(_ chunk: SendableChunk, persist: Bool? = nil, showInRecents: Bool? = nil, callback: StreamServiceCallback? = nil) {
        // Insert a local chunk so the UI can update properly until we get a response from the server.
        if let senderId = BackendClient.instance.session?.id {
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let chunk = LocalChunk(
                url: chunk.url,
                attachments: chunk.attachments,
                duration: chunk.duration,
                externalContentId: chunk.externalContentId,
                reactions: [:], senderId: senderId,
                start: now - Int64(chunk.duration), end: now,
                textSegments: chunk.textSegments)
            self.allChunks.append(chunk)
        }
        StreamService.instance.sendChunk(streamId: self.id, chunk: chunk, persist: persist, showInRecents: showInRecents, callback: callback)
    }

    func setImage(_ image: Intent.Image) {
        StreamService.instance.setImage(stream: self, image: image)
    }

    func setChunkReaction(chunk: Chunk, reaction: String?) {
        StreamService.instance.setChunkReaction(
            chunk: chunk,
            reaction: chunk.userReaction == reaction ? nil : reaction
        )
    }

    func setTitle(_ title: String) {
        StreamService.instance.setTitle(stream: self, title: title)
    }

    /// Update the played until value in the backend.
    func setPlayedUntil(_ playedUntil: Int64) {
        StreamService.instance.setPlayedUntil(stream: self, playedUntil: playedUntil)
    }

    /// Updates the current status for the provided participant in the stream. Only for internal use.
    func setStatusForParticipant(_ participantId: Int64, status: ActivityStatus, estimatedDuration: Int? = nil) {
        guard let index = self.otherParticipants.index(where: { $0.id == participantId }) else {
            return
        }
        let duration: Int
        switch (self.otherParticipants[index].activityStatus, status) {
        case let (from, .idle) where from == .playing || from == .recording:
            // Delay the status change since we can expect another update to arrive any second.
            duration = 2000
            self.otherParticipants[index].update(activityStatus: from, duration: duration)
        case let (oldStatus, status):
            // Use the estimated duration but add on extra time to account for lag. If the duration is unknown, use a high value.
            duration = estimatedDuration.flatMap({ $0 + 3000 }) ?? 120000
            self.otherParticipants[index].update(activityStatus: status, duration: duration)
            if oldStatus != status {
                self.changed.emit()
            }
        }
        if self.status != .idle {
            // Expire the status after the duration (if it's not idle).
            DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + Double(Int64(duration) * Int64(NSEC_PER_MSEC)) / Double(NSEC_PER_SEC)) {
                self.expireStatuses()
            }
        }
    }

    /// Enables push notifications for this stream.
    func unmute() {
        SettingsManager.unmute(stream: self)
    }

    func updateParticipant(_ participant: Participant) {
        guard let index = self.otherParticipants.index(where: { $0.id == participant.id }) else {
            return
        }
        self.otherParticipants.remove(at: index)
        self.otherParticipants.insert(participant, at: index)
        self.changed.emit()
    }

    func updateWithAttachmentData(_ id: String, data: DataType?) -> Attachment? {
        var attachments = (self.data["attachments"] as? DataType) ?? [:]
        attachments[id] = data
        self.data["attachments"] = attachments
        self.updateComputedFields(chunks: false, participants: false, attachments: true)
        self.changed.emit()
        return self.attachments[id]
    }

    // MARK: - Private

    private var allChunks = [PlayableChunk]() {
        didSet {
            self.chunks = nil
        }
    }

    private var cachedImage: UIImage?
    private var cachedImageURL: URL?

    private static let imageDownloader = ImageDownloader()

    private func expireStatuses() {
        var somethingChanged = false
        let now = Date()
        for (index, participant) in self.otherParticipants.enumerated() {
            if participant.activityStatus != .idle && participant.activityStatusEnd < now {
                // The status has expired, so set it to idle.
                self.otherParticipants[index].update(activityStatus: .idle, duration: 0)
                somethingChanged = true
            }
        }
        if somethingChanged {
            self.changed.emit()
        }
    }

    private func updateComputedFields(chunks: Bool = true, participants: Bool = true, attachments: Bool = true) {
        // Clear the cached image if the URL changed.
        // TODO: Fix this logic.
        //if self.cachedImageURL != self.imageURL {
        //    self.cachedImage = nil
        //}
        if chunks {
            let chunksArray = self.data["chunks"] as! [[String: Any]]
            self.allChunks = chunksArray.map { Chunk(streamId: self.id, data: $0) }
        }
        if participants {
            let othersArray = self.data["others"] as! [[String: Any]]
            self.otherParticipants = othersArray.map(Participant.init)
        }
        if attachments {
            let attachmentsData = self.data["attachments"] as? [String: Any] ?? [:]
            var newAttachments = [String: Attachment]()
            for (key, value) in attachmentsData {
                if let attachmentData = value as? [String: Any] {
                    newAttachments[key] = Attachment(data: attachmentData)
                }
            }
            self.attachments = newAttachments
        }
    }
}

// MARK: - Private functions

private func mergeChunks(_ oldChunks: [[String: Any]], withChunks newChunks: [[String: Any]]) -> [[String: Any]] {
    var chunks = oldChunks
    // Merge the new data chunks with the existing chunks.
    var changed = false
    for chunk in newChunks {
        let chunkId = chunk["id"] as! NSNumber
        if let index = chunks.index(where: { ($0["id"] as! NSNumber).compare(chunkId) == .orderedSame }) {
            // Replace chunks that are already in the array.
            chunks.remove(at: index)
            chunks.insert(chunk, at: index)
            continue
        }
        chunks.append(chunk)
        changed = true
    }
    if !changed {
        // Don't sort if nothing changed.
        return chunks
    }
    // Resort the chunks array by timestamps ascending.
    chunks.sort { ($0["start"] as! NSNumber).compare($1["start"] as! NSNumber) == .orderedAscending }
    return chunks
}

// MARK: - Stream Equatable

extension Stream: Equatable {
    static func ==(lhs: Stream, rhs: Stream) -> Bool {
        return lhs.id == rhs.id
    }
}

// MARK: - Stream Hashable

extension Stream: Hashable {
    var hashValue: Int {
        return self.id.hashValue
    }
}
