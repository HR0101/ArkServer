import Foundation

/// PIN 認証の総当たり対策に使う純粋関数群．状態（IP 別の失敗回数）は呼び出し側が保持する．
public enum PINSecurity {
  /// タイミング攻撃を避けるため，長さ・内容を定数時間で比較する．
  public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
    let ab = Array(a.utf8), bb = Array(b.utf8)
    guard ab.count == bb.count else { return false }
    var diff: UInt8 = 0
    for i in 0..<ab.count { diff |= ab[i] ^ bb[i] }
    return diff == 0
  }

  /// 連続失敗 `failCount` 回に対するロックアウト秒数．`maxAttempts` 未満なら nil（ロックしない）．
  /// しきい値到達後は 30s → 60s → 120s … と倍増し，最大 1 時間でキャップする．
  public static func lockoutDelay(failCount: Int, maxAttempts: Int = 5) -> TimeInterval? {
    guard failCount >= maxAttempts else { return nil }
    let over = failCount - maxAttempts
    return min(3600.0, 30.0 * pow(2.0, Double(over)))
  }
}

/// IP ごとの連続失敗回数とロックアウトを保持し、PIN 検証の入口を一本化する。
/// 通常の認証と「削除時のみ PIN」の両方が同じ経路を通ることで、総当たり対策の抜けを防ぐ。
/// サーバーのワーカースレッドから同時に呼ばれるため NSLock で保護する。
public final class PINLockoutTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [String: (count: Int, lockedUntil: Date?)] = [:]
    private let maxAttempts: Int
    private let now: () -> Date

    /// - Parameters:
    ///   - maxAttempts: ロックアウトを始める連続失敗回数。
    ///   - now: 現在時刻の供給元（テストで差し替える）。
    public init(maxAttempts: Int = 5, now: @escaping () -> Date = Date.init) {
        self.maxAttempts = maxAttempts
        self.now = now
    }

    public func isLockedOut(_ ip: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let until = failures[ip]?.lockedUntil, until > now() { return true }
        return false
    }

    /// PIN を実際に提示したリクエストの成否を記録する。成功なら失敗カウンターをリセットする。
    public func record(ip: String, success: Bool) {
        lock.lock(); defer { lock.unlock() }
        if success {
            failures[ip] = nil
            return
        }
        var entry = failures[ip] ?? (count: 0, lockedUntil: nil)
        entry.count += 1
        if let delay = PINSecurity.lockoutDelay(failCount: entry.count, maxAttempts: maxAttempts) {
            entry.lockedUntil = now().addingTimeInterval(delay)
        }
        failures[ip] = entry
    }

    /// ロック中なら PIN の正否にかかわらず false。それ以外は定数時間で比較し、結果を記録して返す。
    public func verify(pin: String, expected: String, ip: String) -> Bool {
        if isLockedOut(ip) { return false }
        let ok = PINSecurity.constantTimeEquals(pin, expected)
        record(ip: ip, success: ok)
        return ok
    }
}
