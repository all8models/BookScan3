import CoreImage
import Vision

/// 양면(스프레드) 도서 감지 및 후보 융합 엔진. 저장된 원본 사진은 절대 임의로 잘라내지 않습니다.
enum BookSpreadDetector {
    struct Candidate { var quad: Quad; var confidence: Double }

    static func detect(_ input: CIImage, manualSpine: Double? = nil) throws -> SpreadDetection {
        let origin = input.transformed(by: CGAffineTransform(translationX: -input.extent.minX, y: -input.extent.minY))
        let factor = min(1, 1000 / max(origin.extent.width, origin.extent.height))
        let image = origin.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        let rectangles = VNDetectRectanglesRequest()
        rectangles.maximumObservations = 10
        rectangles.minimumSize = 0.12
        rectangles.minimumAspectRatio = 0.2
        rectangles.minimumConfidence = 0.45
        rectangles.quadratureTolerance = 40
        let document = VNDetectDocumentSegmentationRequest()
        // 하나의 요청이 실패하더라도 다른 후보 탐색에 영향을 주지 않도록 독립적으로 시도합니다.
        try? VNImageRequestHandler(ciImage: image).perform([rectangles])
        try? VNImageRequestHandler(ciImage: image).perform([document])
        let candidates = (rectangles.results ?? []).map { Candidate(quad: Quad($0), confidence: Double($0.confidence)) }
        if manualSpine == nil, var pair = bestPair(candidates) {
            let leftSupport = boundarySupport(image, quad: pair.geometry.left, skipping: 1)
            let rightSupport = boundarySupport(image, quad: pair.geometry.right, skipping: 3)
            // 인쇄된 텍스트 단락 또한 직사각형으로 인식될 수 있으므로,
            // 자동 분할을 승인하기 전 외곽을 따라 종이/배경 경계 증거가 충분한지 확인합니다.
            if min(leftSupport, rightSupport) < 0.5 || touchesFrame(pair.geometry.outer) {
                pair.confidence = min(pair.confidence, 0.6)
                pair.reason = "종이 바깥 경계가 불확실해요. 글자가 잘리지 않도록 확인해 주세요."
            }
            return pair
        }

        var outerCandidates = candidates
        if let observation = document.results?.first {
            var quad = Quad(observation)
            if let mask = observation.globalSegmentationMask {
                // 세그멘테이션 실루엣을 사용하되, 마스크가 모호하거나 사각형 제안과 너무 크게 어긋나면 Vision 사각형을 유지합니다.
                if let refined = maskOutline(CIImage(cvPixelBuffer: mask.pixelBuffer)), refined.distance(to: quad) < 0.12 { quad = refined }
            }
            outerCandidates.append(Candidate(quad: quad, confidence: Double(observation.confidence)))
        }
        let aspect = image.extent.width / image.extent.height
        let outer = outerCandidates.filter { candidate in
            let q = candidate.quad
            guard q.isValid, q.area > 0.25 else { return false }
            let width = hypot((q.points[1].x - q.points[0].x) * aspect, q.points[1].y - q.points[0].y)
            let height = hypot((q.points[3].x - q.points[0].x) * aspect, q.points[3].y - q.points[0].y)
            return width / max(height, 0.01) > 1.12
        }.max { $0.quad.area * $0.confidence < $1.quad.area * $1.confidence }
        guard let outer else {
            return SpreadDetection(geometry: .guide, confidence: 0, reason: "양쪽 페이지를 함께 찾지 못했어요. 원본에서 경계를 맞춰 주세요.")
        }
        let rectified = ImageProcessor.correct(image, quad: outer.quad)
        let seam = seamEstimate(rectified)
        let top = manualSpine ?? seam.top, bottom = manualSpine ?? seam.bottom
        let geometry = SpreadGeometry.from(outer: outer.quad, top: top, bottom: bottom)
        // 수동 제본선 비율은 외곽 경계의 완전성을 증명하지 못하므로 항상 사용자 검토를 유도합니다.
        let hasBoundary = boundarySupport(image, quad: outer.quad) >= 0.5 && !touchesFrame(outer.quad)
        let confidence = manualSpine == nil && seam.confidence > 0.82 && outer.confidence > 0.75 && hasBoundary ? 0.82 : 0.55
        return SpreadDetection(geometry: geometry, confidence: confidence,
                               reason: confidence >= 0.8 ? "양쪽 페이지와 접힘선을 찾았어요." : "접힘선과 바깥 경계를 확인해 주세요.")
    }

    static func bestPair(_ candidates: [Candidate]) -> SpreadDetection? {
        var best: SpreadDetection?
        for a in candidates {
            for b in candidates {
                let l = a.quad, r = b.quad
                guard l.isValid, r.isValid, l.area > 0.09, r.area > 0.09, l.area + r.area > 0.3 else { continue }
                let lp = l.points, rp = r.points
                guard lp[0].x < rp[0].x, lp[1].x < rp[1].x else { continue }
                let topGap = hypot(lp[1].x - rp[0].x, lp[1].y - rp[0].y)
                let bottomGap = hypot(lp[2].x - rp[3].x, lp[2].y - rp[3].y)
                guard topGap < 0.055, bottomGap < 0.055 else { continue }
                let geometry = SpreadGeometry(points: [lp[0], midpoint(lp[1], rp[0]), rp[1], rp[2], midpoint(lp[2], rp[3]), lp[3]])
                guard geometry.isValid else { continue }
                let confidence = min(a.confidence, b.confidence) * 0.3 + 0.7 - Double(topGap + bottomGap) * 2
                if confidence > (best?.confidence ?? 0) {
                    best = SpreadDetection(geometry: geometry, confidence: confidence, reason: "좌우 페이지의 경계를 찾았어요.")
                }
            }
        }
        return best
    }

    private static func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }

    private static func touchesFrame(_ quad: Quad) -> Bool {
        quad.points.contains { $0.x < 0.008 || $0.y < 0.008 || $0.x > 0.992 || $0.y > 0.992 }
    }

    static func boundarySupport(_ image: CIImage, quad: Quad, skipping: Int? = nil) -> Double {
        let n = 256, gray = grayscale(image, width: 256, height: 256)
        func sample(_ point: CGPoint) -> Double {
            let x = min(n - 1, max(0, Int(point.x * Double(n - 1))))
            let y = min(n - 1, max(0, Int(point.y * Double(n - 1))))
            return gray[y * n + x]
        }
        var support = 0.0, count = 0.0
        for edge in 0..<4 where edge != skipping {
            let a = quad.points[edge], b = quad.points[(edge + 1) % 4]
            let dx = b.x - a.x, dy = b.y - a.y, length = max(0.01, hypot(b.x - a.x, b.y - a.y))
            let normal = CGPoint(x: dy / length * 0.018, y: -dx / length * 0.018)
            for step in 2...17 {
                let t = Double(step) / 20
                let p = CGPoint(x: a.x + dx * t, y: a.y + dy * t)
                let inner = sample(CGPoint(x: p.x + normal.x, y: p.y + normal.y))
                let outer = sample(CGPoint(x: p.x - normal.x, y: p.y - normal.y))
                if inner - outer > 0.07 { support += 1 }
                count += 1
            }
        }
        return support / max(1, count)
    }

    private static func grayscale(_ image: CIImage, width: Int, height: Int) -> [Double] {
        let normalized = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let resized = normalized.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / normalized.extent.width, y: CGFloat(height) / normalized.extent.height))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        ImageProcessor.context.render(resized, toBitmap: &bytes, rowBytes: width * 4, bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        var result = [Double](repeating: 0, count: width * height)
        for i in result.indices {
            let red = Double(bytes[i * 4]) * 0.299
            let green = Double(bytes[i * 4 + 1]) * 0.587
            let blue = Double(bytes[i * 4 + 2]) * 0.114
            result[i] = (red + green + blue) / 255
        }
        return result
    }

    /// 텍스트 경계 대신 Vision 모서리 위치 근처의 외곽 마스크 경계를 정밀 피팅합니다.
    private static func maskOutline(_ image: CIImage) -> Quad? {
        let n = 192, values = grayscale(image, width: 192, height: 192)
        var occupied: [(y: Int, left: Int, right: Int)] = []
        for y in 0..<n {
            let row = (0..<n).filter { values[y * n + $0] > 0.5 }
            if let left = row.first, let right = row.last, right - left > n / 5 { occupied.append((y, left, right)) }
        }
        guard occupied.count > n / 4 else { return nil }
        let bottom = occupied[max(0, occupied.count / 50)], top = occupied[min(occupied.count - 1, occupied.count * 49 / 50)]
        let q = Quad(points: [CGPoint(x: Double(top.left) / 192, y: Double(top.y) / 192), CGPoint(x: Double(top.right) / 192, y: Double(top.y) / 192), CGPoint(x: Double(bottom.right) / 192, y: Double(bottom.y) / 192), CGPoint(x: Double(bottom.left) / 192, y: Double(bottom.y) / 192)])
        return q.isValid ? q : nil
    }

    /// 국소적으로 어두운 연속적인 접힘선(Gutter)을 추적하여 상단 및 하단 절편을 독립적으로 계산합니다.
    /// 신뢰도가 낮은 경우 사용자 수동 조정을 허용하며 임의로 자동 분할을 승인하지 않습니다.
    static func seamEstimate(_ image: CIImage) -> (top: Double, bottom: Double, confidence: Double) {
        let w = 192, h = 160
        let gray = grayscale(image, width: w, height: h)
        return seamEstimate(gray: gray, width: w, height: h)
    }

    static func seamEstimate(gray: [Double], width w: Int, height h: Int) -> (top: Double, bottom: Double, confidence: Double) {
        guard w >= 32, h >= 32, gray.count == w * h else { return (0.5, 0.5, 0) }
        let lo = w / 4, hi = w * 3 / 4, y0 = h / 12, y1 = h * 11 / 12
        var costs = [Double](repeating: 0, count: w)
        var back = [Int](repeating: 0, count: w * h)
        var evidence = [Double](repeating: 0, count: w * h)
        for y in y0..<y1 {
            var next = [Double](repeating: .infinity, count: w)
            for x in lo..<hi {
                let center = (gray[y * w + x - 1] + gray[y * w + x] + gray[y * w + x + 1]) / 3
                let surroundings = (gray[y * w + x - 7] + gray[y * w + x - 5] + gray[y * w + x + 5] + gray[y * w + x + 7]) / 4
                let contrast = max(0, surroundings - center)
                evidence[y * w + x] = contrast
                var previous = x, minimum = Double.infinity
                for px in max(lo, x - 2)...min(hi - 1, x + 2) {
                    let cost = costs[px] + Double(abs(px - x)) * 0.035
                    if cost < minimum { minimum = cost; previous = px }
                }
                next[x] = minimum - contrast + abs(Double(x) / Double(w) - 0.5) * 0.012
                back[y * w + x] = previous
            }
            costs = next
        }
        var x = (lo..<hi).min { costs[$0] < costs[$1] } ?? w / 2
        var path: [(Double, Double)] = [], support = 0.0
        for y in stride(from: y1 - 1, through: y0, by: -1) {
            path.append((Double(y) / Double(h - 1), Double(x) / Double(w - 1)))
            if evidence[y * w + x] > 0.08 { support += 1 }
            x = back[y * w + x]
        }
        let n = Double(path.count), my = path.reduce(0) { $0 + $1.0 } / n, mx = path.reduce(0) { $0 + $1.1 } / n
        let variance = path.reduce(0) { $0 + pow($1.0 - my, 2) }
        let slope = path.reduce(0) { $0 + ($1.0 - my) * ($1.1 - mx) } / max(variance, 0.0001)
        let bottom = mx - slope * my, top = bottom + slope
        let residual = path.reduce(0) { $0 + abs($1.1 - (bottom + slope * $1.0)) } / n
        let confidence = support / n * max(0, 1 - residual * 25)
        return (min(0.78, max(0.22, top)), min(0.78, max(0.22, bottom)), confidence)
    }
}
