import SwiftUI
import AVFoundation

@main
struct XqAssistApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

// MARK: - 模型

final class Model: ObservableObject {
    @Published var pos = Position.start()
    @Published var best: Move?
    @Published var bestText = "—"
    @Published var status = "把摄像头对准整个棋盘，自动识别"
    @Published var info = ""
    @Published var live = true
    @Published var showLabels = true
    @Published var g2i: [Double]? = nil
    @Published var imgSize = CGSize.zero
    @Published var viewBoard = [Int8](repeating: 0, count: 90)
    @Published var viewFlipped = false
    @Published var unknown: [Int] = []
    @Published var forceRedetect = false
    @Published var snapshotMode = false
    var editIdx = 0
    var teachIdx = 0

    let cam = CameraService()
    private let recognizer = Recognizer()
    private var lastRun = Date.distantPast      // 仅摄像头线程使用
    private let frameLock = NSLock()
    private var latestFrame: CVPixelBuffer?
    private var snapshotBuffer: CVPixelBuffer?
    private let recognitionQ = DispatchQueue(label: "xq.snapshot", qos: .userInitiated)
    private var pending: [Int8] = []
    private var stable = 0
    private var gen = 0
    private var mateFound = false
    private let engine = Engine()
    private let work = DispatchQueue(label: "xq.engine", qos: .userInitiated)
    private let mateQ = DispatchQueue(label: "xq.mate", qos: .userInitiated)

    init() {
        cam.onFrame = { [weak self] pb in self?.handle(pb) }
    }

    // MARK: 摄像头线程：约每秒识别一次

    func handle(_ pb: CVPixelBuffer) {
        frameLock.lock()
        latestFrame = pb
        frameLock.unlock()
        if Date().timeIntervalSince(lastRun) < 1.0 { return }
        let s = DispatchQueue.main.sync { (live: live, force: forceRedetect) }
        guard s.live else { return }
        if s.force { DispatchQueue.main.async { self.forceRedetect = false } }
        let res = recognizer.run(pb, force: s.force)
        lastRun = Date()
        DispatchQueue.main.async { self.consider(res) }
    }

    /// 定格当前摄像头画面并识别：用户主动拍照后分析
    func captureAndAnalyze() {
        frameLock.lock()
        let frame = latestFrame
        frameLock.unlock()
        guard let frame = frame else {
            status = "摄像头还没有画面，请稍等后再拍照"
            return
        }
        snapshotMode = true
        live = false
        best = nil
        bestText = "识别中…"
        status = "已定格画面，正在识别棋子"
        cam.pause { [weak self] in
            guard let self = self else { return }
            self.recognitionQ.async {
                let result = self.recognizer.run(frame, force: true)
                DispatchQueue.main.async { self.applySnapshot(result, frame: frame) }
            }
        }
    }

    func resumeCamera() {
        snapshotMode = false
        live = true
        unknown = []
        best = nil
        status = "重新对准棋盘，准备识别"
        cam.resume()
    }

    private func applySnapshot(_ r: Recognition?, frame: CVPixelBuffer) {
        snapshotBuffer = frame
        guard let r = r else {
            g2i = nil
            unknown = []
            bestText = "识别失败"
            status = "没有找到完整棋盘。请让棋盘四边都入镜，手机尽量正对。"
            return
        }
        g2i = r.g2i
        imgSize = CGSize(width: r.imgW, height: r.imgH)
        viewBoard = r.viewBoard
        viewFlipped = r.flipped
        unknown = r.unknown
        info = r.info
        var p = pos
        p.b = r.board
        p.redToMove = !r.flipped
        pos = p
        if !r.unknown.isEmpty {
            best = nil
            bestText = "待纠正"
            status = "还有 \(r.unknown.count) 个棋子没认出。点画面黄色 ?，选择正确棋子；纠正后自动重新分析。"
            return
        }
        if let issue = p.validate() {
            best = nil
            bestText = "局面需检查"
            status = "识别结果校验未通过：\(issue)。可点右上角小棋盘手动修正。"
            return
        }
        analyze()
    }

    private func rerunSnapshot() {
        guard snapshotMode, let frame = snapshotBuffer else { return }
        status = "已记住棋子外观，正在重新识别照片…"
        recognitionQ.async { [weak self] in
            guard let self = self else { return }
            let result = self.recognizer.run(frame, force: true)
            DispatchQueue.main.async { self.applySnapshot(result, frame: frame) }
        }
    }

    /// 用户点了摄像头画面里的某个格子，告诉 App 这是什么棋子
    func teach(_ viewIdx: Int, _ code: Int) {
        recognizer.teach(viewIdx: viewIdx, code: code)
        if snapshotMode { rerunSnapshot() } else { status = "已记住，下一帧生效" }
    }

    // MARK: 识别结果（主线程）：连续 2 次一致才采纳

    private func consider(_ r: Recognition?) {
        guard let r = r else {
            g2i = nil
            unknown = []
            info = ""
            status = "没找到棋盘：让整个棋盘完整进入画面，尽量正对、光线均匀"
            return
        }
        g2i = r.g2i
        imgSize = CGSize(width: r.imgW, height: r.imgH)
        viewBoard = r.viewBoard
        viewFlipped = r.flipped
        unknown = r.unknown
        info = r.info
        if !r.unknown.isEmpty {
            stable = 0
            pending = []
            status = "有 \(r.unknown.count) 个棋子认不出（黄色？）：点一下它，告诉我是什么棋子"
            return
        }

        if r.board == pending { stable += 1 } else { pending = r.board; stable = 1 }
        guard stable >= 2, r.board != pos.b else { return }

        var np = pos
        // 新局面恰好是上一局面走一步合法棋的结果 -> 切换走子方；否则默认轮到近端（你）这一方
        var moved = false
        for m in pos.legalMoves() {
            var t = pos
            t.make(m)
            if t.b == r.board { moved = true; break }
        }
        np.b = r.board
        np.redToMove = moved ? !pos.redToMove : !r.flipped
        pos = np
        analyze()
    }

    // MARK: 手动编辑

    func setPiece(_ i: Int, _ code: Int) {
        live = false
        var p = pos
        p.b[i] = Int8(code)
        pos = p
        analyze()
    }

    func setTurn(red: Bool) {
        var p = pos
        p.redToMove = red
        pos = p
        analyze()
    }

    func copyFEN() {
        UIPasteboard.general.string = pos.fen
        status = "FEN 已复制"
    }

    // MARK: 分析：绝杀搜索 + 云端引擎（本地引擎兜底）

    func analyze() {
        gen += 1
        let g = gen
        let p = pos
        best = nil
        mateFound = false
        if let prob = p.validate() {
            bestText = "—"
            status = "局面不完整/不合法：\(prob)（点右上角小棋盘可手动补全）"
            return
        }
        bestText = "分析中…"
        status = "绝杀搜索 + 云端引擎分析中…"

        mateQ.async { [weak self] in
            guard let self = self else { return }
            let r = MateSearch().find(p, maxMoves: 7, seconds: 2.5, cancelled: { [weak self] in self?.gen != g })
            DispatchQueue.main.async {
                guard g == self.gen, let (mv, n) = r else { return }
                self.mateFound = true
                self.show(mv, p, note: "\(n)步杀！")
            }
        }
        Cloud.bestMove(fen: p.fen) { [weak self] mv in
            guard let self = self, g == self.gen, !self.mateFound else { return }
            if let mv = mv, p.legalMoves().contains(mv) {
                self.show(mv, p, note: "云端引擎")
            } else {
                self.runLocal(p, g)
            }
        }
    }

    private func show(_ mv: Move, _ p: Position, note: String) {
        best = mv
        bestText = (p.redToMove ? "红：" : "黑：") + p.notation(mv)
        status = note
    }

    private func runLocal(_ p: Position, _ g: Int) {
        status = "云端不可用，使用本地引擎…"
        work.async { [weak self] in
            guard let self = self else { return }
            let r = self.engine.search(p, seconds: 3.0, cancelled: { [weak self] in self?.gen != g })
            DispatchQueue.main.async {
                guard g == self.gen, !self.mateFound else { return }
                if let (mv, _, depth) = r {
                    self.show(mv, p, note: "本地引擎（深度\(depth)，联网后更强）")
                } else {
                    self.bestText = "无棋可走"
                    self.status = p.redToMove ? "红方已被将死/困毙" : "黑方已被将死/困毙"
                }
            }
        }
    }
}

// MARK: - 摄像头预览封装

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let g2i: [Double]?
    let imgSize: CGSize
    let viewBoard: [Int8]
    let unknown: [Int]
    let best: Move?
    let flipped: Bool
    let showLabels: Bool
    let onTapCell: (Int) -> Void

    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        v.pl.session = session
        return v
    }

    func updateUIView(_ v: PreviewUIView, context: Context) {
        v.onTapCell = onTapCell
        v.update(g2i: g2i, imgSize: imgSize, viewBoard: viewBoard, unknown: unknown, best: best,
                 flipped: flipped, showLabels: showLabels)
    }
}

// MARK: - 棋盘绘制

struct BoardView: View {
    let pos: Position
    let best: Move?
    let onTap: (Int) -> Void

    var body: some View {
        GeometryReader { g in
            let cell = min(g.size.width / 9, g.size.height / 10)
            let ox = (g.size.width - cell * 9) / 2
            let oy = (g.size.height - cell * 10) / 2
            Canvas { ctx, _ in
                func P(_ r: Int, _ c: Int) -> CGPoint {
                    CGPoint(x: ox + (CGFloat(c) + 0.5) * cell, y: oy + (CGFloat(r) + 0.5) * cell)
                }
                var grid = Path()
                for r in 0..<10 { grid.move(to: P(r, 0)); grid.addLine(to: P(r, 8)) }
                for c in 0..<9 {
                    if c == 0 || c == 8 {
                        grid.move(to: P(0, c)); grid.addLine(to: P(9, c))
                    } else {
                        grid.move(to: P(0, c)); grid.addLine(to: P(4, c))
                        grid.move(to: P(5, c)); grid.addLine(to: P(9, c))
                    }
                }
                for (r0, r1) in [(0, 2), (7, 9)] {
                    grid.move(to: P(r0, 3)); grid.addLine(to: P(r1, 5))
                    grid.move(to: P(r0, 5)); grid.addLine(to: P(r1, 3))
                }
                ctx.stroke(grid, with: .color(.brown), lineWidth: 1)
                ctx.draw(Text("楚 河        汉 界").font(.system(size: cell * 0.4)).foregroundColor(.brown),
                         at: CGPoint(x: ox + cell * 4.5, y: oy + cell * 5))

                for i in 0..<90 where pos.b[i] != 0 {
                    let v = pos.b[i]
                    let p = P(i / 9, i % 9)
                    let rad = cell * 0.42
                    let col: Color = v > 0 ? .red : .black
                    let rect = CGRect(x: p.x - rad, y: p.y - rad, width: rad * 2, height: rad * 2)
                    ctx.fill(Path(ellipseIn: rect), with: .color(Color(red: 0.98, green: 0.93, blue: 0.8)))
                    ctx.stroke(Path(ellipseIn: rect), with: .color(col), lineWidth: 2)
                    ctx.draw(Text(pieceName(v)).font(.system(size: cell * 0.5, weight: .bold)).foregroundColor(col), at: p)
                }

                if let m = best {
                    let a = P(m.from / 9, m.from % 9), t = P(m.to / 9, m.to % 9)
                    var line = Path()
                    line.move(to: a); line.addLine(to: t)
                    ctx.stroke(line, with: .color(.green), style: StrokeStyle(lineWidth: max(2, cell * 0.2), lineCap: .round))
                    for q in [a, t] {
                        let rr = cell * 0.46
                        ctx.stroke(Path(ellipseIn: CGRect(x: q.x - rr, y: q.y - rr, width: rr * 2, height: rr * 2)),
                                   with: .color(.green), lineWidth: 3)
                    }
                }
            }
            .background(Color(red: 0.93, green: 0.8, blue: 0.55))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { v in
                let c = Int(floor((v.location.x - ox) / cell))
                let r = Int(floor((v.location.y - oy) / cell))
                if c >= 0, c < 9, r >= 0, r < 10 { onTap(r * 9 + c) }
            })
        }
    }
}

// MARK: - 手动修正局面（点小棋盘进入）

struct EditorView: View {
    @ObservedObject var m: Model
    @Environment(\.dismiss) private var dismiss
    @State private var showDlg = false

    var body: some View {
        VStack(spacing: 10) {
            Text("点击格子修改棋子（修改后自动识别会暂停，回主界面重新打开）").font(.footnote)
            Text(m.bestText).font(.title2.bold())
            BoardView(pos: m.pos, best: m.best) { idx in
                m.editIdx = idx
                showDlg = true
            }
            .aspectRatio(0.9, contentMode: .fit)
            Picker("", selection: Binding(get: { m.pos.redToMove }, set: { m.setTurn(red: $0) })) {
                Text("红方走").tag(true)
                Text("黑方走").tag(false)
            }
            .pickerStyle(.segmented)
            HStack {
                Button("复制FEN") { m.copyFEN() }
                Button("完成") { dismiss() }
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .confirmationDialog("设置该格", isPresented: $showDlg, titleVisibility: .visible) {
            ForEach([0, 1, 2, 3, 4, 5, 6, 7, -1, -2, -3, -4, -5, -6, -7], id: \.self) { code in
                Button(code == 0 ? "清空" : (code > 0 ? "红" : "黑") + pieceName(Int8(code))) {
                    m.setPiece(m.editIdx, code)
                }
            }
        }
    }
}

// MARK: - 主界面：全屏摄像头 + 叠加最佳走法

struct ContentView: View {
    @StateObject private var m = Model()
    @State private var showEditor = false
    @State private var showTeach = false

    var body: some View {
        ZStack {
            CameraPreview(session: m.cam.session, g2i: m.g2i, imgSize: m.imgSize,
                          viewBoard: m.viewBoard, unknown: m.unknown, best: m.best, flipped: m.viewFlipped,
                          showLabels: m.showLabels,
                          onTapCell: { idx in m.teachIdx = idx; showTeach = true })
                .ignoresSafeArea()
            VStack(spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(m.bestText).font(.title2.bold()).foregroundColor(.white)
                        Text(m.status).font(.footnote).foregroundColor(.white)
                        if !m.info.isEmpty { Text(m.info).font(.caption).foregroundColor(.white) }
                    }
                    .padding(8)
                    .background(Color.black.opacity(0.55))
                    .cornerRadius(10)
                    Spacer(minLength: 0)
                    BoardView(pos: m.pos, best: m.best) { _ in showEditor = true }
                        .frame(width: 117, height: 130)
                        .cornerRadius(6)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white, lineWidth: 1))
                }
                .padding(.horizontal, 8)
                Spacer()
                VStack(spacing: 6) {
                    HStack {
                        Button(m.snapshotMode ? "重新拍摄" : "拍照识别") {
                            if m.snapshotMode { m.resumeCamera() } else { m.captureAndAnalyze() }
                        }
                        .tint(m.snapshotMode ? .orange : .green)
                        Button("重新识别棋盘") { m.forceRedetect = true; m.live = true }
                        Button(m.showLabels ? "隐藏标记" : "显示标记") { m.showLabels.toggle() }
                    }
                    .buttonStyle(.bordered)
                    .font(.footnote)
                    HStack {
                        Toggle("自动识别", isOn: $m.live)
                        Picker("", selection: Binding(get: { m.pos.redToMove }, set: { m.setTurn(red: $0) })) {
                            Text("红走").tag(true)
                            Text("黑走").tag(false)
                        }
                        .pickerStyle(.segmented)
                    }
                    .font(.footnote)
                }
                .padding(10)
                .background(.ultraThinMaterial)
                .cornerRadius(14)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            }
        }
        .onAppear { m.cam.start() }
        .sheet(isPresented: $showEditor) { EditorView(m: m) }
        .confirmationDialog("这个格子是什么棋子？", isPresented: $showTeach, titleVisibility: .visible) {
            ForEach([1, 2, 3, 4, 5, 6, 7, -1, -2, -3, -4, -5, -6, -7], id: \.self) { code in
                Button((code > 0 ? "红" : "黑") + pieceName(Int8(code))) {
                    m.teach(m.teachIdx, code)
                }
            }
        }
    }
}
