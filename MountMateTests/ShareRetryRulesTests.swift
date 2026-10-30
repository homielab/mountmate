//  Created by homielab.com

import NetFS
import XCTest

@testable import MountMate

final class ShareRetryRulesTests: XCTestCase {
  func testRejectedCredentialsStopRetries() {
    for status: Int32 in [
      EAUTH, Int32(ENETFSPWDNEEDSCHANGE), Int32(ENETFSPWDPOLICY), Int32(ENETFSACCOUNTRESTRICTED),
    ] {
      XCTAssertTrue(ShareRetryRules.isCredentialFailure(status), "\(status)")
    }
  }

  func testOtherFailuresKeepRetrying() {
    let statuses: [Int32] = [
      -128,  // userCanceledErr: no login saved, NetFS wanted to ask
      EACCES, EPERM, ENOENT, EEXIST, EBUSY, ETIMEDOUT, ECONNREFUSED, ENETDOWN, ENETUNREACH,
      EHOSTDOWN, EHOSTUNREACH, ENOTSUP, EPROTONOSUPPORT,
      Int32(ENETFSNOSHARESAVAIL), Int32(ENETFSNOAUTHMECHSUPP), Int32(ENETFSNOPROTOVERSSUPP), 0,
    ]
    for status in statuses {
      XCTAssertFalse(ShareRetryRules.isCredentialFailure(status), "\(status)")
    }
  }

  func testOnlyANetFSFailureCanBeACredentialFailure() {
    XCTAssertTrue(ShareRetryRules.isCredentialFailure(.failed("denied", status: EAUTH)))
    XCTAssertFalse(ShareRetryRules.isCredentialFailure(.failed("denied", status: ENETDOWN)))
    // NFS (mount_nfs) and failures before NetFS carry no status.
    XCTAssertFalse(ShareRetryRules.isCredentialFailure(.failed("denied")))
    XCTAssertFalse(ShareRetryRules.isCredentialFailure(.success))
    XCTAssertFalse(ShareRetryRules.isCredentialFailure(.timedOut(mayStillComplete: false)))
  }
}
