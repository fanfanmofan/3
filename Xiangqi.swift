import Foundation

// 棋子编码：红 +1...+7，黑 -1...-7
// 1 帅/将  2 仕/士  3 相/象  4 马  5 车  6 炮  7 兵/卒
// 棋盘 10 行 x 9 列，行 0 在上（黑方），行 9 在下（红方），索引 = 行*9+列

struct Move: Equatable { let from: Int; let to: Int }

let redNames = ["", "帅", "仕", "相", "马", "车", "炮", "兵"]
let blackNames = ["", "将", "士", "象", "马", "车", "炮", "卒"]
let cnNum = ["", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
func pieceName(_ v: Int8) -> String { v > 0 ? redNames[Int(v)] : blackNames[Int(-v)] }

struct Position {
    var b: [Int8]
    var redToMove: Bool

    init(b: [Int8] = [Int8](repeating: 0, count: 90), redToMove: Bool = true) {
        self.b = b
        self.redToMove = redToMove
    }

    static let startFEN = "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w"
    static func start() -> Position { Position(fen: startFEN)! }

    init?(fen: String) {
        self.init()
        let parts = fen.split(separator: " ")
        guard let first = parts.first else { return nil }
        let rows = first.split(separator: "/")
        guard rows.count == 10 else { return nil }
        let map: [Character: Int8] = ["k": 1, "a": 2, "b": 3, "n": 4, "r": 5, "c": 6, "p": 7]
        for (r, row) in rows.enumerated() {
            var c = 0
            for ch in row {
                if let n = ch.wholeNumberValue { c += n; continue }
                guard c < 9, let t = map[Character(ch.lowercased())] else { return nil }
                b[r * 9 + c] = ch.isUppercase ? t : -t
                c += 1
            }
            if c != 9 { return nil }
        }
        redToMove = parts.count < 2 || parts[1] == "w" || parts[1] == "r"
    }

    var fen: String {
        var s = ""
        let ch: [Character] = [" ", "k", "a", "b", "n", "r", "c", "p"]
        for r in 0..<10 {
            var empty = 0
            for c in 0..<9 {
                let v = b[r * 9 + c]
                if v == 0 { empty += 1; continue }
                if empty > 0 { s += String(empty); empty = 0 }
                let x = ch[Int(abs(v))]
                s += v > 0 ? String(x).uppercased() : String(x)
            }
            if empty > 0 { s += String(empty) }
            if r < 9 { s += "/" }
        }
        return s + (redToMove ? " w" : " b")
    }

    // MARK: 走子

    @discardableResult
    mutating func make(_ m: Move) -> Int8 {
        let cap = b[m.to]
        b[m.to] = b[m.from]
        b[m.from] = 0
        redToMove.toggle()
        return cap
    }

    mutating func unmake(_ m: Move, _ cap: Int8) {
        b[m.from] = b[m.to]
        b[m.to] = cap
        redToMove.toggle()
    }

    static let d4: [(Int, Int)] = [(1, 0), (-1, 0), (0, 1), (0, -1)]
    static let dDiag: [(Int, Int)] = [(1, 1), (1, -1), (-1, 1), (-1, -1)]
    // (马腿行偏移, 马腿列偏移, 目标行偏移, 目标列偏移)
    static let horse: [(Int, Int, Int, Int)] = [
        (-1, 0, -2, -1), (-1, 0, -2, 1), (1, 0, 2, -1), (1, 0, 2, 1),
        (0, -1, -1, -2), (0, -1, 1, -2), (0, 1, -1, 2), (0, 1, 1, 2),
    ]

    static func inPalace(_ r: Int, _ c: Int, _ red: Bool) -> Bool {
        c >= 3 && c <= 5 && (red ? (r >= 7 && r <= 9) : (r >= 0 && r <= 2))
    }

    func pseudoMoves(capturesOnly: Bool = false) -> [Move] {
        var out = [Move]()
        out.reserveCapacity(40)
        let red = redToMove
        func add(_ i: Int, _ r: Int, _ c: Int) {
            guard r >= 0, r < 10, c >= 0, c < 9 else { return }
            let tv = b[r * 9 + c]
            if tv != 0 && (tv > 0) == red { return }
            if capturesOnly && tv == 0 { return }
            out.append(Move(from: i, to: r * 9 + c))
        }
        for i in 0..<90 {
            let v = b[i]
            if v == 0 || (v > 0) != red { continue }
            let r = i / 9, c = i % 9
            switch abs(v) {
            case 1:
                for (dr, dc) in Position.d4 where Position.inPalace(r + dr, c + dc, red) { add(i, r + dr, c + dc) }
            case 2:
                for (dr, dc) in Position.dDiag where Position.inPalace(r + dr, c + dc, red) { add(i, r + dr, c + dc) }
            case 3:
                for (dr, dc) in Position.dDiag {
                    let r2 = r + 2 * dr, c2 = c + 2 * dc
                    guard r2 >= 0, r2 < 10, c2 >= 0, c2 < 9 else { continue }
                    if (red ? r2 < 5 : r2 > 4) { continue }      // 不能过河
                    if b[(r + dr) * 9 + c + dc] != 0 { continue } // 塞象眼
                    add(i, r2, c2)
                }
            case 4:
                for (ldr, ldc, dr, dc) in Position.horse {
                    let lr = r + ldr, lc = c + ldc
                    if lr < 0 || lr > 9 || lc < 0 || lc > 8 { continue }
                    if b[lr * 9 + lc] != 0 { continue }           // 蹩马腿
                    add(i, r + dr, c + dc)
                }
            case 5:
                for (dr, dc) in Position.d4 {
                    var rr = r + dr, cc = c + dc
                    while rr >= 0 && rr < 10 && cc >= 0 && cc < 9 {
                        let tv = b[rr * 9 + cc]
                        add(i, rr, cc)
                        if tv != 0 { break }
                        rr += dr; cc += dc
                    }
                }
            case 6:
                for (dr, dc) in Position.d4 {
                    var rr = r + dr, cc = c + dc
                    while rr >= 0 && rr < 10 && cc >= 0 && cc < 9 && b[rr * 9 + cc] == 0 {
                        add(i, rr, cc)
                        rr += dr; cc += dc
                    }
                    rr += dr; cc += dc   // 跳过炮架
                    while rr >= 0 && rr < 10 && cc >= 0 && cc < 9 {
                        let tv = b[rr * 9 + cc]
                        if tv != 0 {
                            if (tv > 0) != red { add(i, rr, cc) }
                            break
                        }
                        rr += dr; cc += dc
                    }
                }
            default:
                let f = red ? -1 : 1
                add(i, r + f, c)
                if (red ? r <= 4 : r >= 5) { add(i, r, c - 1); add(i, r, c + 1) }
            }
        }
        return out
    }

    func kingSquare(red: Bool) -> Int {
        for r in (red ? 7...9 : 0...2) {
            for c in 3...5 where b[r * 9 + c] == (red ? 1 : -1) { return r * 9 + c }
        }
        return -1
    }

    /// 指定一方的将/帅是否被攻击（含将帅对脸）
    func isInCheck(red: Bool) -> Bool {
        let ks = kingSquare(red: red)
        if ks < 0 { return true }
        let kr = ks / 9, kc = ks % 9
        let es: Int8 = red ? -1 : 1
        for (dr, dc) in Position.d4 {
            var r = kr + dr, c = kc + dc
            var screen = false
            while r >= 0 && r < 10 && c >= 0 && c < 9 {
                let v = b[r * 9 + c]
                if v != 0 {
                    if !screen {
                        if v * es > 0 {
                            let t = abs(v)
                            if t == 5 || (t == 1 && dc == 0) { return true }
                        }
                        screen = true
                    } else {
                        if v * es > 0 && abs(v) == 6 { return true }
                        break
                    }
                }
                r += dr; c += dc
            }
        }
        for (dr, dc) in [(-2, -1), (-2, 1), (2, -1), (2, 1), (-1, -2), (1, -2), (-1, 2), (1, 2)] {
            let r = kr + dr, c = kc + dc
            guard r >= 0, r < 10, c >= 0, c < 9, b[r * 9 + c] == 4 * es else { continue }
            let lr = abs(dr) == 2 ? kr + dr / 2 : kr + dr
            let lc = abs(dr) == 2 ? kc + dc : kc + dc / 2
            if b[lr * 9 + lc] == 0 { return true }
        }
        if red {
            if kr >= 1 && b[(kr - 1) * 9 + kc] == -7 { return true }
            if kr >= 5 {
                for dc in [-1, 1] {
                    let c = kc + dc
                    if c >= 0 && c < 9 && b[kr * 9 + c] == -7 { return true }
                }
            }
        } else {
            if kr <= 8 && b[(kr + 1) * 9 + kc] == 7 { return true }
            if kr <= 4 {
                for dc in [-1, 1] {
                    let c = kc + dc
                    if c >= 0 && c < 9 && b[kr * 9 + c] == 7 { return true }
                }
            }
        }
        return false
    }

    func legalMoves() -> [Move] {
        var p = self
        var out = [Move]()
        for m in pseudoMoves() {
            let cap = p.make(m)
            if !p.isInCheck(red: !p.redToMove) { out.append(m) }
            p.unmake(m, cap)
        }
        return out
    }

    /// 局面是否合理；合理返回 nil，否则返回原因
    func validate() -> String? {
        var cnt = [Int](repeating: 0, count: 15)
        for v in b where v != 0 { cnt[Int(v) + 7] += 1 }
        let lim = [0, 1, 2, 2, 2, 2, 2, 5]
        for s in [1, -1] {
            let name = s > 0 ? "红" : "黑"
            if cnt[s + 7] != 1 { return "\(name)方将帅数量不是1" }
            for t in 2...7 where cnt[s * t + 7] > lim[t] { return "\(name)方\(pieceName(Int8(s * t)))过多" }
        }
        if kingSquare(red: true) < 0 || kingSquare(red: false) < 0 { return "将帅不在九宫内" }
        if isInCheck(red: !redToMove) { return "非走子方正被将军（识别可能有误）" }
        return nil
    }

    /// 中文纵线记谱（不处理“前/后”同线歧义）
    func notation(_ m: Move) -> String {
        let v = b[m.from]
        let red = v > 0
        let t = Int(abs(v))
        let fr = m.from / 9, fc = m.from % 9, tr = m.to / 9, tc = m.to % 9
        func col(_ c: Int) -> String { red ? cnNum[9 - c] : String(c + 1) }
        let dr = red ? fr - tr : tr - fr
        let action = dr == 0 ? "平" : (dr > 0 ? "进" : "退")
        let target: String
        if dr == 0 || t == 2 || t == 3 || t == 4 {
            target = col(tc)
        } else {
            target = red ? cnNum[abs(dr)] : String(abs(dr))
        }
        return pieceName(v) + col(fc) + action + target
    }
}

// MARK: - 搜索引擎（alpha-beta + 迭代加深 + 静态搜索）

final class Engine {
    static let val: [Int] = [0, 1000, 20, 20, 40, 90, 45, 10]
    static let mate = 30000
    static let inf = 32000

    private var nodes = 0
    private var deadline = Date()
    private var aborted = false
    private var cancelled: () -> Bool = { false }

    func evaluate(_ p: Position) -> Int {
        var s = 0
        for i in 0..<90 {
            let v = p.b[i]
            if v == 0 { continue }
            let t = Int(abs(v))
            let r = i / 9, c = i % 9
            let red = v > 0
            var x = Engine.val[t]
            if t == 7 {
                if red ? r <= 4 : r >= 5 { x += 15 + (red ? 4 - r : r - 5) * 3 }
            } else if t == 4 || t == 5 || t == 6 {
                x += 4 - abs(c - 4)
            }
            s += red ? x : -x
        }
        return p.redToMove ? s : -s
    }

    private func order(_ m: Move, _ p: Position) -> Int {
        let cap = abs(Int(p.b[m.to]))
        if cap == 0 { return 0 }
        return Engine.val[cap] * 10 - Engine.val[abs(Int(p.b[m.from]))]
    }

    /// 返回 (最佳走法, 评分, 搜索深度)；无合法走法返回 nil
    func search(_ root: Position, seconds: Double, cancelled: @escaping () -> Bool) -> (Move, Int, Int)? {
        self.cancelled = cancelled
        aborted = false
        nodes = 0
        deadline = Date().addingTimeInterval(seconds)
        var p = root
        var moves = p.legalMoves()
        if moves.isEmpty { return nil }
        moves.sort { order($0, p) > order($1, p) }
        var best = moves[0], bestScore = 0, bestDepth = 0
        for depth in 1...12 {
            var alpha = -Engine.inf
            var curBest = moves[0], curScore = -Engine.inf
            for m in moves {
                let cap = p.make(m)
                let s = -negamax(&p, depth - 1, -Engine.inf, -alpha, 1)
                p.unmake(m, cap)
                if aborted { break }
                if s > curScore { curScore = s; curBest = m }
                if s > alpha { alpha = s }
            }
            if aborted { break }
            best = curBest; bestScore = curScore; bestDepth = depth
            if let i = moves.firstIndex(of: best) { moves.remove(at: i); moves.insert(best, at: 0) }
            if abs(bestScore) > Engine.mate - 100 { break }
            if Date() > deadline { break }
        }
        return (best, bestScore, bestDepth)
    }

    private func negamax(_ p: inout Position, _ depth: Int, _ alpha0: Int, _ beta: Int, _ ply: Int) -> Int {
        if aborted { return 0 }
        nodes += 1
        if nodes & 1023 == 0 && (Date() > deadline || cancelled()) { aborted = true; return 0 }
        if depth <= 0 { return quiesce(&p, alpha0, beta, 0) }
        var alpha = alpha0
        var moves = p.pseudoMoves()
        moves.sort { order($0, p) > order($1, p) }
        var legal = 0
        for m in moves {
            let cap = p.make(m)
            if p.isInCheck(red: !p.redToMove) { p.unmake(m, cap); continue }
            legal += 1
            let s = -negamax(&p, depth - 1, -beta, -alpha, ply + 1)
            p.unmake(m, cap)
            if aborted { return 0 }
            if s >= beta { return beta }
            if s > alpha { alpha = s }
        }
        if legal == 0 { return -Engine.mate + ply }   // 象棋中被困毙也算输
        return alpha
    }

    private func quiesce(_ p: inout Position, _ alpha0: Int, _ beta: Int, _ qd: Int) -> Int {
        nodes += 1
        let stand = evaluate(p)
        if stand >= beta { return beta }
        var alpha = max(alpha0, stand)
        if qd >= 6 { return alpha }
        var moves = p.pseudoMoves(capturesOnly: true)
        moves.sort { order($0, p) > order($1, p) }
        for m in moves {
            let cap = p.make(m)
            if p.isInCheck(red: !p.redToMove) { p.unmake(m, cap); continue }
            let s = -quiesce(&p, -beta, -alpha, qd + 1)
            p.unmake(m, cap)
            if s >= beta { return beta }
            if s > alpha { alpha = s }
        }
        return alpha
    }
}

// MARK: - 绝杀搜索（只用将军着法进攻，防守方穷举；找 N 步内的连将杀）

final class MateSearch {
    private var nodes = 0
    private var deadline = Date()
    private var aborted = false
    private var cancelled: () -> Bool = { false }

    private func tick() -> Bool {
        nodes += 1
        if nodes & 4095 == 0 && (Date() > deadline || cancelled()) { aborted = true }
        return aborted
    }

    /// 进攻方走，n = 进攻方还剩几步
    private func attack(_ p: inout Position, _ n: Int) -> Bool {
        if n <= 0 || tick() { return false }
        for m in p.pseudoMoves() {
            let cap = p.make(m)
            var good = false
            // 走完后自己不能被将，且必须将军
            if !p.isInCheck(red: !p.redToMove) && p.isInCheck(red: p.redToMove) {
                good = defend(&p, n)
            }
            p.unmake(m, cap)
            if aborted { return false }
            if good { return true }
        }
        return false
    }

    /// 防守方走：所有合法应着都被杀（或无合法应着=被杀）才算成功
    private func defend(_ p: inout Position, _ n: Int) -> Bool {
        for m in p.pseudoMoves() {
            let cap = p.make(m)
            if p.isInCheck(red: !p.redToMove) { p.unmake(m, cap); continue }
            let ok = attack(&p, n - 1)
            p.unmake(m, cap)
            if aborted { return false }
            if !ok { return false }
        }
        return true
    }

    /// 返回 (第一步, 杀棋总步数)；找不到返回 nil
    func find(_ root: Position, maxMoves: Int, seconds: Double, cancelled: @escaping () -> Bool) -> (Move, Int)? {
        self.cancelled = cancelled
        aborted = false
        nodes = 0
        deadline = Date().addingTimeInterval(seconds)
        var p = root
        let cands = p.legalMoves()
        for n in 1...maxMoves {
            for m in cands {
                let cap = p.make(m)
                var ok = false
                if p.isInCheck(red: p.redToMove) { ok = defend(&p, n) }
                p.unmake(m, cap)
                if aborted { return nil }
                if ok { return (m, n) }
            }
        }
        return nil
    }
}

// MARK: - 云端引擎（ChessDB 象棋云库，背后是顶级引擎 + 海量预计算）

enum Cloud {
    /// UCI 坐标 "h2e2"：列 a-i 从左到右，行 0 在红方底线
    static func parse(_ s: String) -> Move? {
        guard let r = s.range(of: "[a-i][0-9][a-i][0-9]", options: .regularExpression) else { return nil }
        let u = Array(s[r].unicodeScalars)
        let f1 = Int(u[0].value) - 97, r1 = Int(u[1].value) - 48
        let f2 = Int(u[2].value) - 97, r2 = Int(u[3].value) - 48
        return Move(from: (9 - r1) * 9 + f1, to: (9 - r2) * 9 + f2)
    }

    static func bestMove(fen: String, completion: @escaping (Move?) -> Void) {
        func attempt(_ scheme: String, canFallback: Bool) {
            var comp = URLComponents(string: "\(scheme)://www.chessdb.cn/chessdb.php")!
            comp.queryItems = [URLQueryItem(name: "action", value: "querybest"),
                               URLQueryItem(name: "board", value: fen)]
            guard let url = comp.url else { completion(nil); return }
            var req = URLRequest(url: url)
            req.timeoutInterval = 8
            URLSession.shared.dataTask(with: req) { data, _, _ in
                if data == nil && canFallback { attempt("http", canFallback: false); return }
                var mv: Move? = nil
                if let d = data, let s = String(data: d, encoding: .utf8) { mv = parse(s) }
                DispatchQueue.main.async { completion(mv) }
            }.resume()
        }
        attempt("https", canFallback: true)
    }
}
