import Foundation

/// Run an async closure to completion from a synchronous context.
///
/// Only for launch-time checks that must gate startup, before the run loop
/// exists. The work runs on the cooperative pool, so nothing here may hop to
/// the main actor — that would deadlock against this wait.
func runBlocking<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = Box<T>()
    Task.detached(priority: .userInitiated) {
        box.value = await work()
        semaphore.signal()
    }
    semaphore.wait()
    return box.value!
}

private final class Box<T>: @unchecked Sendable {
    var value: T?
}
