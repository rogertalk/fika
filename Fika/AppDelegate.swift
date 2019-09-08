import AudioToolbox
import Crashlytics
import Fabric
import UIKit
import UserNotifications

struct NotificationEvent {
    let type: String
    let data: [String: Any]
}

enum NotificationEventResult {
    case invalidData, other
    case serviceTeamMember(serviceId: String, teamId: String, accountId: Int64)
    case stream(Stream)
    case streamAttachment(Stream, Account, Attachment)
    case streamChunk(Stream, Account, PlayableChunk)
    case streamGone(Stream)
    case streamStatus(Stream, Account, ActivityStatus)
}

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let storyboard: UIStoryboard
    var window: UIWindow?

    static let receivedAuthCode = Event<String>()
    /// Fired when the application changes between active/inactive states.
    static let applicationActiveStateChanged = Event<Bool>()
    /// Fired when the user chooses "Import with fika.io" for a document in another app.
    static let documentImported = Event<Void>()
    /// Fired when a stream is selected externally or indirectly
    static let userSelectedStream = Event<Stream>()

    override init() {
        // TODO: Consider setting up camera already here.
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.makeKeyAndVisible()
        self.window = window
        self.storyboard = UIStoryboard(name: "Main", bundle: nil)
        super.init()
    }

    static func getImportedDocumentURL() -> URL? {
        guard let url = AppDelegate.importedURL else {
            return nil
        }
        AppDelegate.importedURL = nil
        return url
    }

    static func setImportedDocumentURL(to url: URL) {
        AppDelegate.importedURL = url
        AppDelegate.documentImported.emit()
        Answers.logCustomEvent(withName: "Imported Document", customAttributes: [
            "FileType": url.pathExtension.lowercased(),
        ])
    }

    // MARK: - UIApplicationDelegate

    func application(_ app: UIApplication, open url: URL, options: [UIApplicationOpenURLOptionsKey: Any] = [:]) -> Bool {
        if url.isFileURL {
            AppDelegate.setImportedDocumentURL(to: url)
            return true
        }
        switch (url.scheme!, url.host!) {
        case ("fika", "login"):
            if url.pathComponents.count == 3 && url.pathComponents[1] == "code" {
                // Request by URI to log in using an authorization code.
                AppDelegate.receivedAuthCode.emit(url.pathComponents[2])
                return true
            }
        default:
            NSLog("%@", "WARNING: Unhandled URL: \(url)")
        }
        return false
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplicationLaunchOptionsKey: Any]?) -> Bool {
        // TODO: Consider running this on a separate thread to reduce time until camera.
        // Set up event listeners.
        BackendClient.instance.loggedIn.addListener(self, method: AppDelegate.handleLoggedIn)
        BackendClient.instance.loggedOut.addListener(self, method: AppDelegate.handleLoggedOut)
        StreamService.instance.changed.addListener(self, method: AppDelegate.setMeetingReminderNotifications)
        application.keyWindow!.addSubview(VolumeControl())

        let notifCenter = UNUserNotificationCenter.current()
        notifCenter.delegate = self

        // Ask for a device token from APNS.
        application.registerForRemoteNotifications()

        if let session = BackendClient.instance.session {
            if session.isActive {
                // Set up the stream service.
                StreamService.instance.loadFromCache()
            }
            self.setRootViewController("RootNavigation")
        } else {
            self.setRootViewController("Challenge")
        }

        Fabric.with([Crashlytics.self])
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        AppDelegate.applicationActiveStateChanged.emit(true)

        guard let session = BackendClient.instance.session else {
            // Nothing more to do if we're not logged in.
            return
        }
        if (Date() as NSDate).isLaterThan(session.expires as Date!), let token = session.refreshToken {
            // The access token expired, so refresh it.
            // TODO: This also needs to happen automatically when the token is about to expire.
            // TODO: Refresh session logic should be moved into BackendClient.
            Intent.refreshSession(refreshToken: token).perform(BackendClient.instance)
        } else {
            StreamService.instance.loadStreams()
            Intent.getOwnProfile().perform(BackendClient.instance)
        }
    }

    func applicationWillResignActive(_ application: UIApplication) {
        AppDelegate.applicationActiveStateChanged.emit(false)
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        // TODO: Handle background push notifications.
        guard let event = self.parse(userInfo: userInfo) else {
            completionHandler(.failed)
            return
        }
        self.handle(event: event) {
            switch $0 {
            case .invalidData:
                NSLog("WARNING: Failed to handle \(event.type) event")
                completionHandler(.failed)
            default:
                completionHandler(.newData)
            }
        }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        self.notificationToken = deviceToken.hex
        self.putNotificationToken()
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NSLog("%@", "WARNING: Failed to register for remote notifications: \(error)")
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        guard let event = self.parse(notification: notification) else {
            completionHandler([.alert, .badge, .sound])
            return
        }
        self.handle(event: event) {
            guard case .streamChunk = $0 else {
                completionHandler([.alert, .badge, .sound])
                return
            }
            // TODO: Don't show an alert if the stream is already selected.
            completionHandler([.alert, .badge, .sound])
            AudioServicesPlayAlertSound(kSystemSoundID_Vibrate)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        guard let event = self.parse(notification: response.notification) else {
            completionHandler()
            return
        }
        self.handle(event: event) {
            if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
                switch $0 {
                case let .serviceTeamMember(_, _, accountId):
                    let participant = Intent.Participant(accountId: accountId)
                    StreamService.instance.getOrCreateStream(participants: [participant], showInRecents: true) { stream, error in
                        guard let stream = stream, error == nil else {
                            return
                        }
                        AppDelegate.userSelectedStream.emit(stream)
                    }
                case let .stream(stream), let .streamChunk(stream, _, _), let .streamStatus(stream, _, _):
                    AppDelegate.userSelectedStream.emit(stream)
                    break
                default:
                    break
                }
            }
            completionHandler()
        }
    }

    // MARK: - Private

    private static var importedURL: URL?

    private var notificationToken: String?

    private func handle(event: NotificationEvent, callback: ((NotificationEventResult) -> ())? = nil) {
        switch event.type {
        case "account-change":
            guard let data = event.data["account"] as? DataType else {
                callback?(.invalidData)
                return
            }
            BackendClient.instance.updateAccountData(data)
            callback?(.other)
        case "service-team-join":
            guard
                let data = event.data["account"] as? DataType,
                let accountId = (data["id"] as? NSNumber)?.int64Value,
                let serviceId = event.data["service_id"] as? String,
                let teamId = event.data["team_id"] as? String
                else
            {
                callback?(.invalidData)
                return
            }
            callback?(.serviceTeamMember(serviceId: serviceId, teamId: teamId, accountId: accountId))
        case "stream-attachment":
            guard
                let attachmentId = event.data["attachment_id"] as? String,
                let streamId = event.data["stream_id"] as? NSNumber,
                let stream = StreamService.instance.streams[streamId.int64Value],
                let senderId = (event.data["sender_id"] as? NSNumber)?.int64Value,
                let sender = stream.getParticipant(senderId) as? Participant
                else
            {
                callback?(.invalidData)
                return
            }
            if let attachment = stream.updateWithAttachmentData(attachmentId, data: event.data["attachment"] as? [String: Any]) {
                callback?(.streamAttachment(stream, sender, attachment))
            } else {
                // TODO: Stream attachment was removed.
            }
        case "stream-change", "stream-listen", "stream-new", "stream-title":
            guard
                let data = event.data["stream"] as? DataType,
                let stream = StreamService.instance.updateWithStreamData(data: data)
                else
            {
                callback?(.invalidData)
                return
            }
            if event.type == "stream-new" && stream.isVisible {
                StreamService.instance.includeStreamInRecents(stream: stream)
            }
            if
                event.type == "stream-listen",
                let playedUntil = (event.data["played_until"] as? NSNumber)?.int64Value,
                let senderId = (event.data["sender_id"] as? NSNumber)?.int64Value,
                let sender = stream.getParticipant(senderId) as? Participant
            {
                sender.update(playedUntil: playedUntil)
                stream.changed.emit()
            }
            callback?(.stream(stream))
        case "stream-chunk", "stream-chunk-external-play", "stream-chunk-reaction", "stream-chunk-text":
            guard
                let streamId = (event.data["stream_id"] as? NSNumber)?.int64Value,
                let chunkData = event.data["chunk"] as? DataType,
                let chunkId = (chunkData["id"] as? NSNumber)?.int64Value
                else
            {
                callback?(.invalidData)
                return
            }
            func call(_ stream: Stream) {
                guard
                    let chunk = stream.chunks.first(where: { ($0 as? Chunk)?.id == chunkId }),
                    let sender = stream.getParticipant(chunk.senderId)
                    else
                {
                    callback?(.invalidData)
                    return
                }
                callback?(.streamChunk(stream, sender, chunk))
            }
            guard let stream = StreamService.instance.updateWithStreamChunkData(id: streamId, chunkData: chunkData) else {
                // We didn't have the stream locally, so get it from the backend.
                self.loadStream(streamId) {
                    guard let stream = $0 else {
                        callback?(.invalidData)
                        return
                    }
                    call(stream)
                }
                return
            }
            call(stream)
        case "stream-hidden", "stream-leave":
            guard
                let streamId = (event.data["stream_id"] as? NSNumber)?.int64Value,
                let stream = StreamService.instance.streams[streamId]
                else
            {
                // TODO: This probably isn't really invalid data, just missing data.
                callback?(.invalidData)
                return
            }
            StreamService.instance.removeStreamFromRecents(stream: stream)
            callback?(.streamGone(stream))
        case "stream-meeting":
            guard
                let streamId = (event.data["stream_id"] as? NSNumber)?.int64Value,
                let stream = StreamService.instance.streams[streamId]
                else
            {
                callback?(.invalidData)
                return
            }
            callback?(.stream(stream))
        case "stream-participants":
            guard let streamId = (event.data["stream_id"] as? NSNumber)?.int64Value,
                let senderId = (event.data["sender_id"] as? NSNumber)?.int64Value,
                let added = (event.data["added"] as? [NSNumber])?.map({ return $0.int64Value }),
                let removed = (event.data["removed"] as? [NSNumber])?.map({ return $0.int64Value })
                else
            {
                callback?(.invalidData)
                return
            }
            print("Participants change: +\(added) -\(removed)")
            self.loadStream(streamId) {
                guard let stream = $0 else {
                    callback?(.invalidData)
                    return
                }
                guard senderId != BackendClient.instance.session?.id else {
                    callback?(.other)
                    return
                }
                callback?(.stream(stream))
            }
        case "stream-participant-change":
            guard
                let streamId = (event.data["stream_id"] as? NSNumber)?.int64Value,
                let participantData = (event.data["participant"] as? DataType)
                else
            {
                callback?(.invalidData)
                return
            }
            if let stream = StreamService.instance.streams[streamId] {
                let participant = Participant(data: participantData)
                stream.updateParticipant(participant)
                callback?(.stream(stream))
                return
            }
            // The stream didn't exist locally, so load it from the backend.
            self.loadStream(streamId) {
                guard let stream = $0 else {
                    callback?(.invalidData)
                    return
                }
                callback?(.stream(stream))
            }
        case "stream-shown":
            guard let streamId = (event.data["stream_id"] as? NSNumber)?.int64Value else {
                callback?(.invalidData)
                return
            }
            self.loadStream(streamId) {
                guard let stream = $0 else {
                    callback?(.invalidData)
                    return
                }
                callback?(.stream(stream))
            }
        case "stream-status":
            guard
                let status = (event.data["status"] as? String).flatMap({ ActivityStatus(rawValue: $0) }),
                let streamId = (event.data["stream_id"] as? NSNumber)?.int64Value,
                let stream = StreamService.instance.streams[streamId],
                let accountId = (event.data["sender_id"] as? NSNumber)?.int64Value,
                let account = stream.getParticipant(accountId)
                else
            {
                callback?(.invalidData)
                return
            }
            let estimatedDuration = event.data["estimated_duration"] as? Int
            stream.setStatusForParticipant(accountId, status: status, estimatedDuration: estimatedDuration)
            callback?(.streamStatus(stream, account, status))
        default:
            NSLog("%@", "WARNING: Unhandled notification type: \(event.type)")
            callback?(.invalidData)
        }
    }

    private func loadStream(_ streamId: Int64, callback: ((Stream?) -> Void)? = nil) {
        Intent.getStream(id: streamId).perform(BackendClient.instance) {
            guard let data = $0.data , $0.successful else {
                NSLog("%@", "WARNING: Failed to get stream with id \(streamId)")
                callback?(nil)
                return
            }
            let stream = StreamService.instance.updateWithStreamData(data: data)!
            if stream.isVisible {
                StreamService.instance.includeStreamInRecents(stream: stream)
            }
            callback?(stream)
        }
    }

    /// Parse the type and data of the push notification, validating everything along the way.
    private func parse(notification: UNNotification) -> NotificationEvent? {
        return self.parse(userInfo: notification.request.content.userInfo)
    }

    /// Parse the type and data of the push notification, validating everything along the way.
    private func parse(userInfo: [AnyHashable: Any]) -> NotificationEvent? {
        // Every push notification should contain a type, a version and some data.
        guard let type = userInfo["type"] as? String else {
            NSLog("%@", "WARNING: Failed to get type of notification\n\(userInfo)")
            return nil
        }
        guard let version = userInfo["api_version"] as? Int, version >= 23 else {
            NSLog("%@", "WARNING: Incompatible notification version\n\(userInfo)")
            return nil
        }
        var data = [String: Any]()
        for (key, value) in userInfo {
            guard let key = key as? String else {
                continue
            }
            // Skip the non-data keys.
            if key == "api_version" || key == "aps" || key == "type" {
                continue
            }
            data[key] = value
        }
        return NotificationEvent(type: type, data: data)
    }

    private func putNotificationToken() {
        guard BackendClient.instance.session != nil, let token = self.notificationToken else {
            return
        }
        let intent = Intent.registerDeviceForPush(
            deviceId: UIDevice.current.identifierForVendor?.uuidString,
            environment: Bundle.main.apsEnvironment,
            platform: "ios",
            token: token)
        intent.perform(BackendClient.instance) {
            if !$0.successful, let error = $0.error {
                NSLog("%@", "WARNING: Failed to store device token in backend: \(error)")
            }
        }
    }

    private func setRootViewController(_ identifier: String) {
        self.window!.rootViewController = self.storyboard.instantiateViewController(withIdentifier: identifier)
    }

    // MARK: - Events

    private func handleLoggedIn(session: Session) {
        self.putNotificationToken()
    }

    private func handleLoggedOut() {
        self.setRootViewController("GetStarted")
    }

    private func setMeetingReminderNotifications() {
        StreamService.instance.streams.values.forEach { stream in
            guard let meetingTimes = stream.meetingTimes else {
                return
            }

            UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
                // Remove unnecessary notifs
                var remove = [String]()
                requests.forEach { request in
                    guard request.content.categoryIdentifier == "meeting",
                        (request.content.userInfo["stream_id"] as? NSNumber)?.int64Value == stream.id,
                        let components = (request.trigger as? UNCalendarNotificationTrigger)?.dateComponents else {
                        return
                    }

                    if !meetingTimes.contains(components) {
                        remove.append(request.identifier)
                    }
                }
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: remove)

                // Add missing notifs
                meetingTimes.forEach { components in
                    guard !requests.contains(where: {
                        ($0.content.userInfo["stream_id"] as? NSNumber)?.int64Value == stream.id &&
                            ($0.trigger as? UNCalendarNotificationTrigger)?.dateComponents == components
                    }) else {
                        return
                    }

                    let content = UNMutableNotificationContent()
                    content.title = "Sync Time!"
                    content.body = "What's your update for \(stream.shortTitle)?"
                    content.categoryIdentifier = "meeting"
                    content.sound = UNNotificationSound.default()
                    content.userInfo = ["type": "stream-meeting", "stream_id": NSNumber(value: stream.id)]
                    let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
                    let id = "\(stream.id).Time=\(components.hour!):\(components.minute!)Weekday=\(components.weekday!)"
                    let notif = UNNotificationRequest(identifier: "io.fika.Fika.TeamSyncNotif.\(id)", content: content, trigger: trigger)
                    UNUserNotificationCenter.current().add(notif, withCompletionHandler: nil)
                }
            }
        }
    }
}
