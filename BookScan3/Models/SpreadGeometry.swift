import Foundation
import CoreGraphics

/// Six points in upright source-image coordinates (origin at bottom left).
/// Clockwise: outer TL, spine top, outer TR, outer BR, spine bottom, outer BL.
struct SpreadGeometry: Codable, Equatable, Sendable {
    var points: [CGPoint]
    static let guide = SpreadGeometry(points: [
        CGPoint(x: 0.06, y: 0.94), CGPoint(x: 0.5, y: 0.94), CGPoint(x: 0.94, y: 0.94),
        CGPoint(x: 0.94, y: 0.06), CGPoint(x: 0.5, y: 0.06), CGPoint(x: 0.06, y: 0.06)
    ])
    var left: Quad { Quad(points: [points[0], points[1], points[4], points[5]]) }
    var right: Quad { Quad(points: [points[1], points[2], points[3], points[4]]) }
    var outer: Quad { Quad(points: [points[0], points[2], points[3], points[5]]) }
    var isValid: Bool {
        guard points.count == 6, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }) else { return false }
        return left.isValid && right.isValid && outer.isValid && left.area > 0.025 && right.area > 0.025
            && points[0].x < points[1].x && points[1].x < points[2].x
            && points[5].x < points[4].x && points[4].x < points[3].x
            && points[1].y > points[4].y
    }
    func distance(to other: Self) -> CGFloat {
        guard points.count == 6, other.points.count == 6 else { return 1 }
        return zip(points, other.points).map { hypot($0.x - $1.x, $0.y - $1.y) }.max() ?? 1
    }
    static func from(outer: Quad, top: Double, bottom: Double) -> Self {
        func mix(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
        let p = outer.points
        return Self(points: [p[0], mix(p[0], p[1], top), p[1], p[2], mix(p[3], p[2], bottom), p[3]])
    }
}

struct SpreadDetection: Sendable {
    var geometry: SpreadGeometry
    var confidence: Double
    var reason: String
    var canAutoSave: Bool { geometry.isValid && confidence >= 0.8 }
}

struct SpreadCaptureHint: Sendable {
    var geometry: SpreadGeometry
    var aspect: CGFloat
    var observedAt: Date
    func agrees(with geometry: SpreadGeometry, aspect: CGFloat, now: Date = Date()) -> Bool {
        // A changed field of view or stale observation cannot authorize an automatic crop.
        now.timeIntervalSince(observedAt) < 2 && abs(self.aspect - aspect) < 0.04
            && self.geometry.distance(to: geometry) < 0.08
    }
}

struct CaptureRecord: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var bookID: UUID
    var sourceName: String
    var createdAt = Date()
    var geometry: SpreadGeometry = .guide
    var filter: ScanFilter
    var curvature: Double
    var isPending = true
    var note = "여섯 점을 책의 바깥 모서리와 접힘선 양끝에 맞춰 주세요."
    var processingVersion = 2
}

extension Quad {
    var isValid: Bool {
        guard points.count == 4, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }), area > 0.01 else { return false }
        // Vision corner order is clockwise; reject concave, collapsed and crossed quads.
        for i in 0..<4 {
            let a = points[i], b = points[(i + 1) % 4], c = points[(i + 2) % 4]
            if (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x) >= -0.0001 { return false }
        }
        return true
    }
}
