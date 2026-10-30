//  Created by homielab.com

import Foundation
import dnssd

/// Resolves one Bonjour service ("My NAS", "_smb._tcp", "local.") to the
/// host name and port it announces, with DNSServiceResolve. The completion
/// runs once on `queue`: with the address, or nil after an error or the
/// timeout. `cancel()` stops it without calling the completion.
final class BonjourServiceLookup {
  private let queue: DispatchQueue
  private var ref: DNSServiceRef?
  private var completion: ((ResolvedServiceAddress?) -> Void)?
  private var finished = false
  /// Keeps the lookup alive while DNS-SD may still call back into it.
  private var keepAlive: BonjourServiceLookup?

  init(queue: DispatchQueue) {
    self.queue = queue
  }

  func start(
    _ service: DiscoveredShareService, timeout: TimeInterval,
    completion: @escaping (ResolvedServiceAddress?) -> Void
  ) {
    queue.async { [self] in
      guard !finished else { return }
      self.completion = completion
      keepAlive = self
      var newRef: DNSServiceRef?
      let context = Unmanaged.passUnretained(self).toOpaque()
      let error = DNSServiceResolve(
        &newRef, 0, 0, service.name, service.type, service.domain,
        bonjourResolveReply, context)
      guard error == DNSServiceErrorType(kDNSServiceErr_NoError), let newRef else {
        finish(nil)
        return
      }
      ref = newRef
      guard DNSServiceSetDispatchQueue(newRef, queue) == DNSServiceErrorType(kDNSServiceErr_NoError)
      else {
        finish(nil)
        return
      }
      queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
        self?.finish(nil)
      }
    }
  }

  /// Stops the lookup; the completion is not called.
  func cancel() {
    queue.async { [self] in
      completion = nil
      finish(nil)
    }
  }

  /// Runs on `queue` (DNS-SD calls back there).
  fileprivate func finish(_ address: ResolvedServiceAddress?) {
    if finished { return }
    finished = true
    if let ref {
      DNSServiceRefDeallocate(ref)
      self.ref = nil
    }
    let done = completion
    completion = nil
    keepAlive = nil
    done?(address)
  }
}

private func bonjourResolveReply(
  _ ref: DNSServiceRef?, _ flags: DNSServiceFlags, _ interfaceIndex: UInt32,
  _ error: DNSServiceErrorType, _ fullName: UnsafePointer<CChar>?,
  _ hostTarget: UnsafePointer<CChar>?, _ port: UInt16, _ txtLength: UInt16,
  _ txtRecord: UnsafePointer<UInt8>?, _ context: UnsafeMutableRawPointer?
) {
  guard let context else { return }
  let lookup = Unmanaged<BonjourServiceLookup>.fromOpaque(context).takeUnretainedValue()
  guard error == DNSServiceErrorType(kDNSServiceErr_NoError), let hostTarget else {
    lookup.finish(nil)
    return
  }
  lookup.finish(
    ResolvedServiceAddress(
      hostTarget: String(cString: hostTarget), port: Int(UInt16(bigEndian: port))))
}
