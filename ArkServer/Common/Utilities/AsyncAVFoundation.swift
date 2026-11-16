// ArkServer/Common/Utilities/AsyncAVFoundation.swift

import AVFoundation
import Foundation

/// スレッドをまたいで所有権を移す非 Sendable 値を包む補助。
/// 生成元のスレッドで設定を終えたあと、受け取り側だけが使う値に使う。
nonisolated struct UncheckedSendableBox<Value>: @unchecked Sendable {
  let value: Value

  init(_ value: Value) {
    self.value = value
  }
}

/// AVFoundation の同期的な読み出しや書き出しを、Task 取消とスレッド安全を保ったまま非同期で扱うための補助。
nonisolated enum AsyncAVFoundation {
  /// macOS の仮想マシン(`kern.hv_vmm_present == 1`)上で動作しているかどうか。
  static var isVirtualMachine: Bool {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    return sysctlbyname("kern.hv_vmm_present", &value, &size, nil, 0) == 0 && value == 1
  }

  /// `AVAssetReader` の開始と読み出しを専用の `DispatchQueue` 上で実行する。
  /// Swift の協調スレッドプールを塞がず、Task 取消時にも呼び出し元が即座に戻れるようにする。
  ///
  /// `startReading()` の実行中に `cancelReading()` を呼ぶと AVFoundation の内部で落ちるため、
  /// 開始中の取消は `startReading()` が戻ってから実行する。
  static func runReader<Output: Sendable>(
    _ reader: AVAssetReader,
    queueLabel: String,
    startError: @escaping @Sendable (String) -> any Error,
    readError: @escaping @Sendable (String) -> any Error,
    body: @escaping @Sendable (_ isCancelled: @escaping @Sendable () -> Bool) throws -> Output
  ) async throws -> Output {
    try Task.checkCancellation()
    let session = ReaderSession<Output>(reader: reader)
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard session.arm(continuation: continuation) else {
          continuation.resume(throwing: CancellationError())
          return
        }
        DispatchQueue(label: queueLabel, qos: .userInitiated).async {
          session.execute(startError: startError, readError: readError, body: body)
        }
      }
    } onCancel: {
      session.cancel()
    }
  }

  /// `AVAssetWriter.finishWriting` を Task 取消に対応させて待つ。
  static func finishWriting(_ writer: AVAssetWriter) async throws {
    if Task.isCancelled {
      if writer.status == .writing { writer.cancelWriting() }
      throw CancellationError()
    }
    let session = FinishWritingSession(writer: writer)
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        session.start(with: continuation)
      }
    } onCancel: {
      session.cancel()
    }
  }
}

private enum ReaderStartOutcome { case cancelled, failed, ready }

private nonisolated final class ReaderSession<Output: Sendable>: @unchecked Sendable {
  private enum Phase {
    case idle
    case starting
    case running
    case finished
  }

  private let lock = NSLock()
  private let reader: AVAssetReader
  private var phase: Phase = .idle
  private var isCancelled = false
  private var didCancelReader = false
  private var continuation: CheckedContinuation<Output, any Error>?

  init(reader: AVAssetReader) {
    self.reader = reader
  }

  func arm(continuation: CheckedContinuation<Output, any Error>) -> Bool {
    lock.withLock {
      guard !isCancelled else { return false }
      self.continuation = continuation
      return true
    }
  }

  func cancel() {
    let (cont, shouldCancelReader) = lock.withLock { () -> (CheckedContinuation<Output, any Error>?, Bool) in
      isCancelled = true
      let cont = continuation
      continuation = nil
      // startReading() の途中で cancelReading() を呼ぶと内部で落ちるため、running 中だけ即時中止する。
      let canCancelNow = (phase == .running && !didCancelReader)
      if canCancelNow { didCancelReader = true }
      return (cont, canCancelNow)
    }
    if shouldCancelReader {
      reader.cancelReading()
    }
    cont?.resume(throwing: CancellationError())
  }

  func execute(
    startError: (String) -> any Error,
    readError: (String) -> any Error,
    body: (_ isCancelled: @escaping @Sendable () -> Bool) throws -> Output
  ) {
    let canStart = lock.withLock { () -> Bool in
      guard !isCancelled else {
        phase = .finished
        return false
      }
      phase = .starting
      return true
    }
    guard canStart else {
      resume(throwing: CancellationError())
      return
    }

    let started = reader.startReading()

    let outcome = lock.withLock { () -> (ReaderStartOutcome, Bool) in
      if isCancelled {
        phase = .finished
        if started, !didCancelReader {
          didCancelReader = true
          return (.cancelled, true)
        }
        return (.cancelled, false)
      }
      guard started else {
        phase = .finished
        return (.failed, false)
      }
      phase = .running
      return (.ready, false)
    }

    if outcome.1 {
      reader.cancelReading()
    }
    switch outcome.0 {
    case .cancelled:
      resume(throwing: CancellationError())
      return
    case .failed:
      resume(throwing: startError(reader.error?.localizedDescription ?? "開始できませんでした．"))
      return
    case .ready:
      break
    }

    let cancelledCheck: @Sendable () -> Bool = { [self] in
      lock.withLock { isCancelled }
    }

    let result: Result<Output, any Error>
    do {
      let value = try body(cancelledCheck)
      if cancelledCheck() {
        result = .failure(CancellationError())
      } else if reader.status == .failed {
        result = .failure(readError(reader.error?.localizedDescription ?? "原因不明です．"))
      } else {
        result = .success(value)
      }
    } catch {
      result = .failure(cancelledCheck() ? CancellationError() : error)
    }

    let shouldCancelReader = lock.withLock { () -> Bool in
      phase = .finished
      guard !didCancelReader else { return false }
      let reading = (reader.status == .reading)
      if reading { didCancelReader = true }
      return reading
    }
    if shouldCancelReader {
      reader.cancelReading()
    }

    switch result {
    case .success(let value):
      resume(returning: value)
    case .failure(let error):
      resume(throwing: error)
    }
  }

  private func resume(returning value: Output) {
    let cont = lock.withLock { () -> CheckedContinuation<Output, any Error>? in
      defer { continuation = nil }
      return continuation
    }
    cont?.resume(returning: value)
  }

  private func resume(throwing error: any Error) {
    let cont = lock.withLock { () -> CheckedContinuation<Output, any Error>? in
      defer { continuation = nil }
      return continuation
    }
    cont?.resume(throwing: error)
  }
}

private nonisolated final class FinishWritingSession: @unchecked Sendable {
  private let lock = NSLock()
  private let writer: AVAssetWriter
  private var isCancelled = false
  private var isFinished = false
  private var didCancelWriter = false
  private var continuation: CheckedContinuation<Void, any Error>?

  init(writer: AVAssetWriter) {
    self.writer = writer
  }

  func start(with continuation: CheckedContinuation<Void, any Error>) {
    let (shouldStart, shouldCancelWriter) = lock.withLock { () -> (Bool, Bool) in
      guard !isCancelled else {
        let canCancel = (!didCancelWriter && writer.status == .writing)
        if canCancel { didCancelWriter = true }
        return (false, canCancel)
      }
      self.continuation = continuation
      return (true, false)
    }
    if shouldCancelWriter {
      writer.cancelWriting()
    }
    guard shouldStart else {
      continuation.resume(throwing: CancellationError())
      return
    }
    writer.finishWriting { [self] in
      complete()
    }
  }

  func complete() {
    let (cont, cancelled) = lock.withLock { () -> (CheckedContinuation<Void, any Error>?, Bool) in
      isFinished = true
      let cont = continuation
      continuation = nil
      return (cont, isCancelled)
    }
    if cancelled {
      cont?.resume(throwing: CancellationError())
    } else {
      cont?.resume(returning: ())
    }
  }

  func cancel() {
    let (cont, shouldCancelWriter) = lock.withLock { () -> (CheckedContinuation<Void, any Error>?, Bool) in
      isCancelled = true
      let cont = continuation
      continuation = nil
      let canCancel = (!isFinished && !didCancelWriter && writer.status == .writing)
      if canCancel { didCancelWriter = true }
      return (cont, canCancel)
    }
    if shouldCancelWriter {
      writer.cancelWriting()
    }
    cont?.resume(throwing: CancellationError())
  }
}
