import Foundation

/// 会话注册表：集中管理在线会话，负责广播视频帧与事件。
public final class SessionRegistry {
    private let queue = DispatchQueue(label: "macscreen.registry")
    private var sessions: [Session] = []
    /// 视频背压上限：会话发送积压超过该值则丢帧。
    public var videoBacklogLimit = 3

    public init() {}

    public func add(_ session: Session) {
        queue.async { self.sessions.append(session) }
    }

    public func remove(_ session: Session) {
        queue.async { self.sessions.removeAll { $0 === session } }
    }

    public func count() -> Int {
        queue.sync { sessions.filter { !$0.isClosed }.count }
    }

    /// 广播 JPEG 视频帧（订阅了视频且无积压的会话）。
    public func broadcastVideo(_ jpeg: Data) {
        let snapshot = queue.sync { sessions }
        for session in snapshot {
            session.deliverVideoFrame(jpeg)
        }
    }

    /// 广播 JSON 事件（如 capture-state）。
    public func broadcastEvent(_ event: ServerEvent) {
        let snapshot = queue.sync { sessions }
        for session in snapshot {
            session.send(event)
        }
    }
}
