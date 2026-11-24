import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import Vision

// 几何计算统一用 "k-px" = 像素 / 1000（竖直方向的相机画面坐标）
let K: Double = 1000

// MARK: - 单应性

/// 4 点精确解：src -> dst
func homography(src: [CGPoint], dst: [CGPoint]) -> [Double]? {
    var A = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
    for i in 0..<4 {
        let x = Double(src[i].x), y = Double(src[i].y)
        let X = Double(dst[i].x), Y = Double(dst[i].y)
        A[2 * i] = [x, y, 1, 0, 0, 0, -x * X, -y * X, X]
        A[2 * i + 1] = [0, 0, 0, x, y, 1, -x * Y, -y * Y, Y]
    }
    for col in 0..<8 {
        var piv = col
        for r in col..<8 where abs(A[r][col]) > abs(A[piv][col]) { piv = r }
        if abs(A[piv][col]) < 1e-12 { return nil }
        A.swapAt(piv, col)
        for r in 0..<8 where r != col {
            let f = A[r][col] / A[col][col]
            for k in col..<9 { A[r][k] -= f * A[col][k] }
        }
    }
    return (0..<8).map { A[$0][8] / A[$0][$0] } + [1.0]
}

func applyH(_ h: [Double], _ x: Double, _ y: Double) -> CGPoint {
    let w = h[6] * x + h[7] * y + h[8]
    return CGPoint(x: (h[0] * x + h[1] * y + h[2]) / w, y: (h[3] * x + h[4] * y + h[5]) / w)
}

func invert3(_ h: [Double]) -> [Double]? {
    let a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7], i = h[8]
    let det = a * (e * i - f * hh) - b * (d * i - f * g) + c * (d * hh - e * g)
    if abs(det) < 1e-14 { return nil }
    return [(e * i - f * hh) / det, (c * hh - b * i) / det, (b * f - c * e) / det,
            (f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det,
            (d * hh - e * g) / det, (b * g - a * hh) / det, (a * e - b * d) / det]
}

// MARK: - 摄像头

final class CameraService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    var onFrame: ((CVPixelBuffer) -> Void)?
    private let queue = DispatchQueue(label: "xq.camera")
    private var last = Date.distantPast
    private var started = false

    func start() {
        if started { return }
        started = true
        AVCaptureDevice.requestAccess(for: .video) { ok in
            guard ok else { return }
            self.queue.async {
                self.configure()
                self.session.startRunning()
            }
        }
    }

    /// 拍照定格时停止视频流；完成后回调，避免识别与摄像头回调并发
    func pause(completion: (() -> Void)? = nil) {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
            completion?()
        }
    }

    /// 用户点击“重新拍摄”时恢复视频流
    func resume() {
        queue.async {
            if self.started && !self.session.isRunning { self.session.startRunning() }
        }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .hd1920x1080
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: dev),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        let out = AVCaptureVideoDataOutput()
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(out) { session.addOutput(out) }
        session.commitConfiguration()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = Date()
        guard now.timeIntervalSince(last) > 0.3, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        last = now
        onFrame?(pb)
    }
}

// MARK: - 全屏预览：叠加网格 / 识别标记 / 最佳走法箭头；点击格子可纠正棋子

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var pl: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    private let gridLayer = CAShapeLayer()
    private let arrowOutline = CAShapeLayer()
    private let arrowLayer = CAShapeLayer()
    private var labels: [CATextLayer] = []

    var onTapCell: ((Int) -> Void)?
    private var g2i: [Double]? = nil
    private var imgSize = CGSize.zero
    private var viewBoard: [Int8] = []
    private var unknown: [Int] = []
    private var best: Move?
    private var flipped = false
    private var showLabels = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        pl.videoGravity = .resizeAspectFill
        gridLayer.fillColor = nil
        gridLayer.strokeColor = UIColor.systemGreen.withAlphaComponent(0.7).cgColor
        gridLayer.lineWidth = 1
        arrowOutline.fillColor = nil
        arrowOutline.strokeColor = UIColor.white.cgColor
        arrowOutline.lineWidth = 11
        arrowOutline.lineCap = .round
        arrowOutline.lineJoin = .round
        arrowOutline.zPosition = 9
        arrowLayer.fillColor = nil
        arrowLayer.strokeColor = UIColor(red: 0.1, green: 0.85, blue: 0.2, alpha: 1).cgColor
        arrowLayer.lineWidth = 6
        arrowLayer.lineCap = .round
        arrowLayer.lineJoin = .round
        arrowLayer.zPosition = 10
        layer.addSublayer(gridLayer)
        layer.addSublayer(arrowOutline)
        layer.addSublayer(arrowLayer)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        redraw()
    }

    func update(g2i: [Double]?, imgSize: CGSize, viewBoard: [Int8], unknown: [Int],
                best: Move?, flipped: Bool, showLabels: Bool) {
        self.g2i = g2i
        self.imgSize = imgSize
        self.viewBoard = viewBoard
        self.unknown = unknown
        self.best = best
        self.flipped = flipped
        self.showLabels = showLabels
        redraw()
    }

    private func scaleInfo() -> (s: Double, ox: Double, oy: Double)? {
        let iw = Double(imgSize.width), ih = Double(imgSize.height)
        if iw <= 0 || ih <= 0 { return nil }
        let vw = Double(bounds.width), vh = Double(bounds.height)
        let s = max(vw / iw, vh / ih)
        return (s, (vw - iw * s) / 2, (vh - ih * s) / 2)
    }

    /// 视图网格 (列, 行) -> 屏幕坐标（预览是 aspect-fill，竖屏正向）
    private func map(_ c: Double, _ r: Double) -> CGPoint? {
        guard let h = g2i, let si = scaleInfo() else { return nil }
        let p = applyH(h, c, r)
        let x = Double(p.x) * K, y = Double(p.y) * K
        if !x.isFinite || !y.isFinite { return nil }
        return CGPoint(x: x * si.s + si.ox, y: y * si.s + si.oy)
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        guard let h = g2i, let inv = invert3(h), let si = scaleInfo() else { return }
        let p = g.location(in: self)
        let x = (Double(p.x) - si.ox) / si.s / K
        let y = (Double(p.y) - si.oy) / si.s / K
        let q = applyH(inv, x, y)
        let gx = Double(q.x), gy = Double(q.y)
        if !gx.isFinite || !gy.isFinite { return }
        let c = Int(gx.rounded()), r = Int(gy.rounded())
        if c >= 0 && c <= 8 && r >= 0 && r <= 9 { onTapCell?(r * 9 + c) }
    }

    private func arrowPath(_ a: CGPoint, _ t: CGPoint) -> UIBezierPath {
        let p = UIBezierPath()
        p.move(to: a)
        p.addLine(to: t)
        let ang = atan2(t.y - a.y, t.x - a.x)
        let L: CGFloat = 20
        for s in [CGFloat.pi / 6, -CGFloat.pi / 6] {
            p.move(to: t)
            p.addLine(to: CGPoint(x: t.x - L * cos(ang + s), y: t.y - L * sin(ang + s)))
        }
        for q in [a, t] {
            p.append(UIBezierPath(ovalIn: CGRect(x: q.x - 20, y: q.y - 20, width: 40, height: 40)))
        }
        return p
    }

    private func redraw() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        gridLayer.frame = bounds
        arrowOutline.frame = bounds
        arrowLayer.frame = bounds

        let grid = UIBezierPath()
        if g2i != nil {
            for c in 0...8 {
                if let a = map(Double(c), 0), let b = map(Double(c), 9) { grid.move(to: a); grid.addLine(to: b) }
            }
            for r in 0...9 {
                if let a = map(0, Double(r)), let b = map(8, Double(r)) { grid.move(to: a); grid.addLine(to: b) }
            }
        }
        gridLayer.path = grid.cgPath

        func vp(_ i: Int) -> CGPoint? {
            let r = i / 9, c = i % 9
            return flipped ? map(Double(8 - c), Double(9 - r)) : map(Double(c), Double(r))
        }
        if let mv = best, let a = vp(mv.from), let t = vp(mv.to) {
            let path = arrowPath(a, t).cgPath
            arrowOutline.path = path
            arrowLayer.path = path
        } else {
            arrowOutline.path = nil
            arrowLayer.path = nil
        }

        var items: [(CGPoint, String, UIColor, UIColor)] = []
        if showLabels, viewBoard.count == 90 {
            for i in 0..<90 where viewBoard[i] != 0 {
                if let p = map(Double(i % 9), Double(i / 9)) {
                    let v = viewBoard[i]
                    items.append((p, pieceName(v), v > 0 ? UIColor.red : UIColor.black,
                                  UIColor.white.withAlphaComponent(0.8)))
                }
            }
        }
        for i in unknown {
            if let p = map(Double(i % 9), Double(i / 9)) {
                items.append((p, "?", UIColor.black, UIColor.yellow))
            }
        }
        while labels.count < items.count {
            let t = CATextLayer()
            t.contentsScale = UIScreen.main.scale
            t.alignmentMode = .center
            t.fontSize = 14
            t.cornerRadius = 10
            layer.addSublayer(t)
            labels.append(t)
        }
        for (i, t) in labels.enumerated() {
            if i < items.count {
                let it = items[i]
                t.isHidden = false
                t.string = it.1
                t.foregroundColor = it.2.cgColor
                t.backgroundColor = it.3.cgColor
                t.frame = CGRect(x: it.0.x - 10, y: it.0.y - 10, width: 20, height: 19)
            } else {
                t.isHidden = true
            }
        }
    }
}

// MARK: - OCR（Vision 文字识别，认棋子上的字）

struct Hit {
    var type: Int       // 1 帅 2 仕 3 相 4 马 5 车 6 炮 7 兵
    var side: Int       // 1 红, -1 黑, 0 字形无法区分
    var conf: Float
}

enum Glyph {
    static let table: [Character: (Int, Int)] = [
        "帅": (1, 1), "帥": (1, 1), "将": (1, -1), "將": (1, -1),
        "仕": (2, 1), "士": (2, -1), "相": (3, 1), "象": (3, -1),
        "马": (4, 0), "馬": (4, 0), "傌": (4, 1),
        "车": (5, 0), "車": (5, 0), "俥": (5, 1),
        "炮": (6, 0), "砲": (6, -1), "兵": (7, 1), "卒": (7, -1),
    ]
}

enum OCR {
    static func run(_ cg: CGImage, minHeight: Float) -> [Hit] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.recognitionLanguages = ["zh-Hans", "zh-Hant"]
        req.usesLanguageCorrection = false
        req.minimumTextHeight = minHeight
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do { try handler.perform([req]) } catch { return [] }
        var hits = [Hit]()
        for obs in req.results ?? [] {
            // 不只取 Vision 的第一候选；斜拍、反光、字体磨损时第二/第三候选常更正确。
            for cand in obs.topCandidates(3) {
                for ch in cand.string {
                    if let g = Glyph.table[ch] {
                        hits.append(Hit(type: g.0, side: g.1, conf: cand.confidence))
                    }
                }
            }
        }
        return hits
    }

    /// 矩形候选（棋盘外框），返回 k-px 坐标，顺序 左上/右上/右下/左下
    static func rectangles(_ cg: CGImage) -> [[CGPoint]] {
        let req = VNDetectRectanglesRequest()
        req.minimumAspectRatio = 0.30
        req.maximumAspectRatio = 1.35
        req.minimumSize = 0.10
        req.minimumConfidence = 0.2
        req.maximumObservations = 12
        req.quadratureTolerance = 60
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do { try handler.perform([req]) } catch { return [] }
        let W = Double(cg.width), H = Double(cg.height)
        func p(_ q: CGPoint) -> CGPoint {
            CGPoint(x: Double(q.x) * W / K, y: (1 - Double(q.y)) * H / K)
        }
        var out = [[CGPoint]]()
        for o in req.results ?? [] {
            out.append([p(o.topLeft), p(o.topRight), p(o.bottomRight), p(o.bottomLeft)])
        }
        return out
    }
}

// MARK: - 灰度图（用于对齐棋盘线）

final class Gray {
    let w: Int
    let h: Int
    let scale: Double
    let d: [UInt8]

    init(_ cg: CGImage, scale: Double) {
        let ww = max(1, Int(Double(cg.width) * scale))
        let hh = max(1, Int(Double(cg.height) * scale))
        var data = [UInt8](repeating: 0, count: ww * hh)
        data.withUnsafeMutableBytes { buf in
            if let c = CGContext(data: buf.baseAddress, width: ww, height: hh, bitsPerComponent: 8,
                                 bytesPerRow: ww, space: CGColorSpaceCreateDeviceGray(),
                                 bitmapInfo: CGImageAlphaInfo.none.rawValue) {
                c.interpolationQuality = .medium
                c.draw(cg, in: CGRect(x: 0, y: 0, width: ww, height: hh))
            }
        }
        self.w = ww
        self.h = hh
        self.scale = scale
        self.d = data
    }

    /// 双线性取样；越界返回 -1
    func at(_ x: Double, _ y: Double) -> Double {
        if !(x >= 0 && y >= 0 && x < 1e6 && y < 1e6) { return -1 }
        let xi = Int(x), yi = Int(y)
        if xi >= w - 1 || yi >= h - 1 { return -1 }
        let fx = x - Double(xi), fy = y - Double(yi)
        let i0 = yi * w + xi
        let a = Double(d[i0]), b = Double(d[i0 + 1])
        let c = Double(d[i0 + w]), e = Double(d[i0 + w + 1])
        let top = a + (b - a) * fx
        let bot = c + (e - c) * fx
        return top + (bot - top) * fy
    }
}

// MARK: - 用棋盘线自动对齐网格（不需要棋子）

enum Geo {
    static let gridCorners = [CGPoint(x: 0, y: 0), CGPoint(x: 8, y: 0), CGPoint(x: 8, y: 9), CGPoint(x: 0, y: 9)]

    /// 网格四角（k-px）对应的棋盘线"暗线对比度"，越大越贴合
    static func objective(_ G: Gray, _ corners: [CGPoint], shift: Double = 0) -> Double {
        guard let h = homography(src: gridCorners, dst: corners) else { return 0 }
        let f = K * G.scale
        let d = 0.13
        var total = 0.0
        var cnt = 0
        func lum(_ c: Double, _ r: Double) -> Double {
            let p = applyH(h, c, r)
            return G.at(Double(p.x) * f, Double(p.y) * f)
        }
        func add(_ c: Double, _ r: Double, vertical: Bool) {
            let v0 = lum(c, r)
            let v1 = vertical ? lum(c - d, r) : lum(c, r - d)
            let v2 = vertical ? lum(c + d, r) : lum(c, r + d)
            if v0 < 0 || v1 < 0 || v2 < 0 { return }
            cnt += 1
            let ct = (v1 + v2) / 2 - v0
            if ct > 0 { total += ct }
        }
        let nv = 36, nh = 32
        for ci in 0...8 {
            let cc = Double(ci) + shift
            for k in 0..<nv {
                let r = (Double(k) + 0.5) / Double(nv) * 9
                if ci >= 1 && ci <= 7 && r > 4 && r < 5 { continue }      // 楚河汉界处没有竖线
                add(cc, r, vertical: true)
            }
        }
        for ri in 0...9 {
            let rr = Double(ri) + shift
            for k in 0..<nh { add((Double(k) + 0.5) / Double(nh) * 8, rr, vertical: false) }
        }
        return cnt > 0 ? total / Double(cnt) : 0
    }

    /// 坐标下降：逐个角点上下左右微调，步长逐级减半
    static func refine(_ G: Gray, _ start: [CGPoint], step0: Double) -> ([CGPoint], Double) {
        var p = start
        var best = objective(G, p)
        var step = step0
        while step > 0.0015 {
            var improved = true
            var iters = 0
            while improved && iters < 6 {
                improved = false
                iters += 1
                for i in 0..<4 {
                    for axis in 0..<2 {
                        for sgn in [-1.0, 1.0] {
                            var q = p
                            if axis == 0 { q[i].x += CGFloat(sgn * step) } else { q[i].y += CGFloat(sgn * step) }
                            let v = objective(G, q)
                            if v > best { best = v; p = q; improved = true }
                        }
                    }
                }
            }
            step *= 0.5
        }
        return (p, best)
    }

    static func hypotheses(quads: [[CGPoint]], imgW: Double, imgH: Double) -> [[CGPoint]] {
        var out = [[CGPoint]]()
        for q in quads where q.count == 4 {
            for a in [0.0, 0.2, 0.4, 0.6, 0.8, 1.0, 1.3, 1.6, 2.0] {
                let mx = a / (8 + 2 * a), my = a / (9 + 2 * a)
                func bil(_ u: Double, _ v: Double) -> CGPoint {
                    let w0 = (1 - u) * (1 - v), w1 = u * (1 - v), w2 = u * v, w3 = (1 - u) * v
                    var x: Double = w0 * Double(q[0].x)
                    x += w1 * Double(q[1].x)
                    x += w2 * Double(q[2].x)
                    x += w3 * Double(q[3].x)
                    var y: Double = w0 * Double(q[0].y)
                    y += w1 * Double(q[1].y)
                    y += w2 * Double(q[2].y)
                    y += w3 * Double(q[3].y)
                    return CGPoint(x: x, y: y)
                }
                out.append([bil(mx, my), bil(1 - mx, my), bil(1 - mx, 1 - my), bil(mx, 1 - my)])
            }
        }
        // 兜底：画面中央的几种大小
        let W = imgW / K, H = imgH / K
        for wf in [0.7, 0.8, 0.9, 0.98] {
            let gw = wf * W, gh = gw * 9 / 8
            if gh > 0.95 * H { continue }
            let cx = W / 2, cy = H * 0.45
            out.append([CGPoint(x: cx - gw / 2, y: cy - gh / 2), CGPoint(x: cx + gw / 2, y: cy - gh / 2),
                        CGPoint(x: cx + gw / 2, y: cy + gh / 2), CGPoint(x: cx - gw / 2, y: cy + gh / 2)])
        }
        return out
    }

    /// 返回 (四角, 对比度, 质量=对比度/半格偏移基线)
    static func detect(_ G: Gray, quads: [[CGPoint]], imgW: Double, imgH: Double) -> ([CGPoint], Double, Double)? {
        let hyps = hypotheses(quads: quads, imgW: imgW, imgH: imgH)
        var scored = hyps.map { ($0, objective(G, $0)) }
        scored.sort { $0.1 > $1.1 }
        var bestC: [CGPoint]? = nil
        var bestV = -1.0
        for (c, _) in scored.prefix(6) {
            let r = refine(G, c, step0: 0.035)
            if r.1 > bestV { bestV = r.1; bestC = r.0 }
        }
        guard let bc = bestC else { return nil }
        let nullV = objective(G, bc, shift: 0.5)
        let quality = bestV / max(nullV, 0.5)
        if quality < 1.4 || bestV < 2.5 { return nil }
        return (bc, bestV, quality)
    }
}

// MARK: - 图像处理：竖直化、透视校正、格子特征

final class Rectified {
    let cg: CGImage
    let rgba: [UInt8]
    let lum: [UInt8]
    init(cg: CGImage, rgba: [UInt8], lum: [UInt8]) { self.cg = cg; self.rgba = rgba; self.lum = lum }
}

enum Analyzer {
    static let ctx = CIContext()
    static let cell = 96, W = 864, H = 960      // 校正后每格 96 像素，交叉点在格子中心

    /// 摄像头缓冲区是横向的，转成竖直（与竖屏预览一致）
    static func upright(_ pb: CVPixelBuffer) -> CGImage? {
        let ci = CIImage(cvPixelBuffer: pb).oriented(.right)
        return ctx.createCGImage(ci, from: ci.extent)
    }

    static func rectify(_ up: CGImage, g2i: [Double]) -> Rectified? {
        let ih = Double(up.height)
        func q(_ x: Double, _ y: Double) -> CGPoint {
            let p = applyH(g2i, x, y)
            return CGPoint(x: Double(p.x) * K, y: ih - Double(p.y) * K)    // CoreImage 原点在左下
        }
        let tl = q(-0.5, -0.5), tr = q(8.5, -0.5), br = q(8.5, 9.5), bl = q(-0.5, 9.5)
        for p in [tl, tr, br, bl] where !(p.x.isFinite && p.y.isFinite) { return nil }
        let f = CIFilter.perspectiveCorrection()
        f.inputImage = CIImage(cgImage: up)
        f.topLeft = tl
        f.topRight = tr
        f.bottomRight = br
        f.bottomLeft = bl
        guard let out = f.outputImage else { return nil }
        let e = out.extent
        guard e.width > 10, e.height > 10, e.width.isFinite, e.height.isFinite else { return nil }
        let t = CGAffineTransform(translationX: -e.origin.x, y: -e.origin.y)
            .concatenating(CGAffineTransform(scaleX: CGFloat(W) / e.width, y: CGFloat(H) / e.height))
        guard let cg = ctx.createCGImage(out.transformed(by: t), from: CGRect(x: 0, y: 0, width: W, height: H)) else { return nil }
        var data = [UInt8](repeating: 0, count: W * H * 4)
        let ok: Bool = data.withUnsafeMutableBytes { buf in
            guard let c = CGContext(data: buf.baseAddress, width: W, height: H, bitsPerComponent: 8,
                                    bytesPerRow: W * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            c.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
            return true
        }
        guard ok else { return nil }
        var lum = [UInt8](repeating: 0, count: W * H)
        for i in 0..<(W * H) {
            let pr: Int = Int(data[4 * i])
            let pg: Int = Int(data[4 * i + 1])
            let pbl: Int = Int(data[4 * i + 2])
            let lv: Int = (299 * pr + 587 * pg + 114 * pbl) / 1000
            lum[i] = UInt8(lv)
        }
        return Rectified(cg: cg, rgba: data, lum: lum)
    }

    /// "这个格子有棋子"的得分：中心圆盘与格子四角底色的色差 + 棋子边框处的暗/红像素比例
    static func cellScore(_ R: Rectified, _ r: Int, _ c: Int) -> Float {
        let cx = c * cell + cell / 2, cy = r * cell + cell / 2
        var n1 = 0, dr = 0, dg = 0, db = 0
        var nc = 0, cr = 0, cg2 = 0, cb = 0
        var nr = 0, ink = 0
        // 棋子圆盘边缘的环形对比度：对斜拍、木纹/棋盘线干扰更稳。
        var innerLum = 0, innerN = 0, outerLum = 0, outerN = 0
        for dy in -47...47 {
            for dx in -47...47 {
                let d2 = dx * dx + dy * dy
                let o = (cy + dy) * W + cx + dx
                let p = o * 4
                if d2 <= 676 {
                    n1 += 1
                    dr += Int(R.rgba[p]); dg += Int(R.rgba[p + 1]); db += Int(R.rgba[p + 2])
                }
                let radius2 = dx * dx + dy * dy
                if radius2 >= 28 * 28 && radius2 <= 36 * 36 {
                    innerLum += Int(R.lum[o]); innerN += 1
                } else if radius2 >= 41 * 41 && radius2 <= 46 * 46 {
                    outerLum += Int(R.lum[o]); outerN += 1
                }
                if d2 >= 1156 && d2 <= 1936 {
                    nr += 1
                    let rr = Int(R.rgba[p]), gg = Int(R.rgba[p + 1]), bb = Int(R.rgba[p + 2])
                    let isRed: Bool = rr > 110 && rr > 2 * gg && rr > 2 * bb
                    if isRed || Int(R.lum[o]) < 90 { ink += 1 }
                }
                if abs(dx) >= 36 && abs(dy) >= 36 {
                    nc += 1
                    cr += Int(R.rgba[p]); cg2 += Int(R.rgba[p + 1]); cb += Int(R.rgba[p + 2])
                }
            }
        }
        let a = Float(max(n1, 1)), b = Float(max(nc, 1))
        let ex: Float = Float(dr) / a - Float(cr) / b
        let ey: Float = Float(dg) / a - Float(cg2) / b
        let ez: Float = Float(db) / a - Float(cb) / b
        let sq: Float = ex * ex + ey * ey + ez * ez
        let cdist: Float = sq.squareRoot() / 255
        let ring: Float = Float(ink) / Float(max(nr, 1))
        let edge: Float = abs(Float(innerLum) / Float(max(innerN, 1)) - Float(outerLum) / Float(max(outerN, 1))) / 255
        return cdist + 0.6 * ring + 0.35 * edge
    }

    /// 格子中心 72x72 区域的 24x24 灰度描述子（圆形掩码，零均值、单位长度），用来认"见过的棋子"
    static func descriptor(_ R: Rectified, _ r: Int, _ c: Int) -> [Float] {
        let cx = c * cell + cell / 2, cy = r * cell + cell / 2
        var d = [Float](repeating: 0, count: 576)
        var mean: Float = 0, cnt: Float = 0
        for j in 0..<24 {
            for i in 0..<24 {
                let ii = i - 12, jj = j - 12
                if ii * ii + jj * jj > 144 { continue }
                var s = 0
                for yy in 0..<3 {
                    for xx in 0..<3 {
                        let x = cx - 36 + i * 3 + xx
                        let y = cy - 36 + j * 3 + yy
                        s += Int(R.lum[y * W + x])
                    }
                }
                let v: Float = Float(s) / 9
                d[j * 24 + i] = v
                mean += v; cnt += 1
            }
        }
        mean /= cnt
        var nrm: Float = 0
        for j in 0..<24 {
            for i in 0..<24 {
                let ii = i - 12, jj = j - 12
                if ii * ii + jj * jj > 144 { continue }
                d[j * 24 + i] -= mean
                nrm += d[j * 24 + i] * d[j * 24 + i]
            }
        }
        nrm = nrm.squareRoot()
        if nrm > 1e-3 { for k in 0..<576 { d[k] /= nrm } }
        return d
    }

    /// 格子里字的颜色：1 红, -1 黑, 0 不确定
    static func colorSide(_ R: Rectified, _ c: Int, _ r: Int) -> Int {
        let cx = c * cell + cell / 2, cy = r * cell + cell / 2
        var n = 0, red = 0, dark = 0
        for dy in -34...34 {
            for dx in -34...34 where dx * dx + dy * dy <= 1156 {
                let o = (cy + dy) * W + cx + dx
                let p = o * 4
                let rr = Int(R.rgba[p]), gg = Int(R.rgba[p + 1]), bb = Int(R.rgba[p + 2])
                n += 1
                let isRed: Bool = rr > 110 && rr > 2 * gg && rr > 2 * bb
                if isRed { red += 1 } else if Int(R.lum[o]) < 90 { dark += 1 }
            }
        }
        let fr = Float(red) / Float(n), fd = Float(dark) / Float(n)
        if fr > 0.015 && fr * 3 > fd { return 1 }
        if fd > 0.02 { return -1 }
        return 0
    }

    /// 对透视校正后的格子做多尺度裁剪；先切掉交叉点/网格线，再旋转适配棋子朝向。
    static func paddedCrop(_ R: Rectified, _ r: Int, _ c: Int, quarterTurns: Int, inset: Int) -> CGImage? {
        let safeInset = max(0, min(inset, 22))
        let rect = CGRect(x: c * cell + safeInset, y: r * cell + safeInset,
                          width: cell - 2 * safeInset, height: cell - 2 * safeInset)
        guard let crop = R.cg.cropping(to: rect) else { return nil }
        let S = 288
        guard let g = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        g.setFillColor(UIColor.white.cgColor)
        g.fill(CGRect(x: 0, y: 0, width: S, height: S))
        if quarterTurns != 0 {
            g.translateBy(x: CGFloat(S) / 2, y: CGFloat(S) / 2)
            g.rotate(by: CGFloat(quarterTurns) * .pi / 2)
            g.translateBy(x: -CGFloat(S) / 2, y: -CGFloat(S) / 2)
        }
        g.interpolationQuality = .high
        g.draw(crop, in: CGRect(x: 30, y: 30, width: 228, height: 228))
        return g.makeImage()
    }

    /// 生成灰度高对比副本，帮助识别暗字、反光和颜色偏移的棋子。
    static func contrastImage(_ image: CGImage) -> CGImage? {
        let f = CIFilter.colorControls()
        f.inputImage = CIImage(cgImage: image)
        f.saturation = 0
        f.contrast = 1.55
        f.brightness = 0.015
        guard let out = f.outputImage else { return nil }
        return ctx.createCGImage(out, from: out.extent)
    }

    /// 返回棋子编码（红正黑负）。多方向、多裁剪、多对比度投票，降低斜拍和反光漏识。
    static func ocrCell(_ R: Rectified, _ r: Int, _ c: Int) -> Int {
        var votes: [Int: Float] = [:]
        // 角度已由单应性拉正，棋子字样仍可能上下/侧向；测试四个方向。
        for turn in 0..<4 {
            for inset in [8, 16] { // 细裁去网格；宽裁保留棋子边缘/较大字样
                guard let img = paddedCrop(R, r, c, quarterTurns: turn, inset: inset) else { continue }
                let variants = [img, contrastImage(img)].compactMap { $0 }
                for variant in variants {
                    let hits = OCR.run(variant, minHeight: 0.075)
                    for h in hits where h.conf >= 0.18 {
                        var side = h.side
                        if side == 0 { side = colorSide(R, c, r) }
                        if side != 0 {
                            let code = side * h.type
                            votes[code, default: 0] += h.conf
                        }
                    }
                }
            }
            // 很有把握的结果无需继续跑所有增强图，控制拍照识别耗时。
            if let best = votes.max(by: { $0.value < $1.value }), best.value >= 1.35 {
                return best.key
            }
        }
        guard let best = votes.max(by: { $0.value < $1.value }), best.value >= 0.35 else { return 0 }
        return best.key
    }
}

// MARK: - 一次完整识别

struct Recognition {
    var viewBoard: [Int8]      // 摄像头里看到的方向
    var board: [Int8]          // 规范方向（红下黑上）
    var flipped: Bool          // 摄像头里红方在上
    var unknown: [Int]         // 有棋子但认不出的格子（视图索引）
    var g2i: [Double]          // 网格 -> 竖直图像 (k-px)
    var imgW: Double
    var imgH: Double
    var count: Int
    var info: String
}

final class Recognizer {
    // 仅摄像头线程使用
    private var corners: [CGPoint]? = nil
    private var baseObj = 0.0
    // 主线程 / 摄像头线程共用，加锁
    private let lock = NSLock()
    private var bank: [(code: Int, d: [Float])] = []
    private var lastDescs: [Int: [Float]] = [:]

    private func dot(_ a: [Float], _ b: [Float]) -> Float {
        var s: Float = 0
        for k in 0..<a.count { s += a[k] * b[k] }
        return s
    }

    private func matchBank(_ d: [Float]) -> (Int, Float)? {
        lock.lock()
        defer { lock.unlock() }
        var bc = 0
        var bs: Float = -2
        for e in bank {
            let s = dot(e.d, d)
            if s > bs { bs = s; bc = e.code }
        }
        return bs > -2 ? (bc, bs) : nil
    }

    private func learn(_ code: Int, _ d: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        for e in bank where e.code == code && dot(e.d, d) > 0.97 { return }
        bank.append((code, d))
        if bank.count > 300 { bank.removeFirst(bank.count - 300) }
    }

    /// 用户在画面上点格子纠正：记住这个外观对应的棋子（并清掉与之冲突的旧记忆）
    func teach(viewIdx: Int, code: Int) {
        lock.lock()
        let d = lastDescs[viewIdx]
        lock.unlock()
        guard let desc = d, code != 0 else { return }
        lock.lock()
        bank.removeAll { $0.code != code && dot($0.d, desc) > 0.85 }
        lock.unlock()
        learn(code, desc)
    }

    func run(_ pb: CVPixelBuffer, force: Bool) -> Recognition? {
        let t0 = Date()
        guard let up = Analyzer.upright(pb) else { return nil }
        let imgW = Double(up.width), imgH = Double(up.height)
        let G = Gray(up, scale: 0.5)
        if force { corners = nil }

        var curObj = 0.0
        var quality = 0.0
        if let c = corners {
            // 跟踪：每秒在上次位置附近微调，手机轻微移动也能跟上
            let r = Geo.refine(G, c, step0: 0.008)
            if r.1 < 0.55 * baseObj { corners = nil } else {
                corners = r.0
                baseObj = max(baseObj, r.1)
                curObj = r.1
            }
        }
        if corners == nil {
            let quads = OCR.rectangles(up)
            guard let d = Geo.detect(G, quads: quads, imgW: imgW, imgH: imgH) else { return nil }
            corners = d.0
            baseObj = d.1
            curObj = d.1
            quality = d.2
        }
        guard let cs = corners, let g2i = homography(src: Geo.gridCorners, dst: cs),
              let R = Analyzer.rectify(up, g2i: g2i) else { corners = nil; return nil }
        if quality == 0 {
            let nullV = Geo.objective(G, cs, shift: 0.5)
            quality = curObj / max(nullV, 0.5)
        }

        // 哪些格子有棋子：对 90 个格子的得分做两类聚类
        var sc = [Float](repeating: 0, count: 90)
        for r in 0..<10 {
            for c in 0..<9 { sc[r * 9 + c] = Analyzer.cellScore(R, r, c) }
        }
        let lo = sc.min() ?? 0, hi = sc.max() ?? 0
        var c0 = lo, c1 = hi
        for _ in 0..<10 {
            var s0: Float = 0, n0: Float = 0, s1: Float = 0, n1: Float = 0
            for v in sc {
                if abs(v - c0) <= abs(v - c1) { s0 += v; n0 += 1 } else { s1 += v; n1 += 1 }
            }
            if n0 > 0 { c0 = s0 / n0 }
            if n1 > 0 { c1 = s1 / n1 }
        }
        let thr = c0 + 0.30 * (c1 - c0)
        var occupied = [Int]()
        if c1 - c0 > 0.10 {
            for i in 0..<90 where sc[i] > thr { occupied.append(i) }
        }

        // 先用"见过的棋子"快速匹配，匹配不上的才做文字识别
        var codes = [Int](repeating: 0, count: 90)
        var descs: [Int: [Float]] = [:]
        var todo = [Int]()
        for i in occupied {
            let d = Analyzer.descriptor(R, i / 9, i % 9)
            descs[i] = d
            if let m = matchBank(d), m.1 >= 0.8 { codes[i] = m.0 } else { todo.append(i) }
        }
        if !todo.isEmpty {
            let todoList = todo
            var res = [Int](repeating: 0, count: todoList.count)
            res.withUnsafeMutableBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                DispatchQueue.concurrentPerform(iterations: todoList.count) { k in
                    let i = todoList[k]
                    base[k] = Analyzer.ocrCell(R, i / 9, i % 9)
                }
            }
            for (k, i) in todoList.enumerated() where res[k] != 0 {
                codes[i] = res[k]
                if let d = descs[i] { learn(res[k], d) }
            }
        }
        lock.lock()
        lastDescs = descs
        lock.unlock()

        var view = [Int8](repeating: 0, count: 90)
        var unknown = [Int]()
        var count = 0
        for i in occupied {
            if codes[i] != 0 { view[i] = Int8(codes[i]); count += 1 } else { unknown.append(i) }
        }

        // 摄像头里红方在上就整盘旋转 180°
        var flipped = false
        if let rk = view.firstIndex(of: 1) {
            flipped = rk / 9 <= 4
        } else if let bk = view.firstIndex(of: -1) {
            flipped = bk / 9 >= 5
        }
        var board = [Int8](repeating: 0, count: 90)
        for i in 0..<90 where view[i] != 0 {
            let r = i / 9, c = i % 9
            let ci = flipped ? (9 - r) * 9 + (8 - c) : i
            board[ci] = view[i]
        }
        let elapsed = Date().timeIntervalSince(t0)
        var info = "识别 \(count) 子"
        if !unknown.isEmpty { info += "，\(unknown.count) 个认不出" }
        let qs = String(format: "%.1f", quality)
        let es = String(format: "%.1f", elapsed)
        info += " · 网格匹配 \(qs) · 用时 \(es)s"
        return Recognition(viewBoard: view, board: board, flipped: flipped, unknown: unknown,
                           g2i: g2i, imgW: imgW, imgH: imgH, count: count, info: info)
    }
}
