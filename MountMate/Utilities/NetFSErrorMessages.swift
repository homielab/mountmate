//  Created by homielab.com

import Foundation

// Readable messages for failed NetFS mounts. Pure functions: they only need
// the share, the mount point and a localizer, so they are tested directly.
extension NetworkMountManager {
  /// Symbolic name of a NetFS / errno status, shown next to the number in
  /// error details and logs; nil for codes without a well-known name.
  static func netFSStatusName(_ status: Int32) -> String? {
    switch status {
    case EPERM: return "EPERM"
    case ENOENT: return "ENOENT"
    case EACCES: return "EACCES"
    case EBUSY: return "EBUSY"
    case EEXIST: return "EEXIST"
    case ETIMEDOUT: return "ETIMEDOUT"
    case ECONNREFUSED: return "ECONNREFUSED"
    case ENETDOWN: return "ENETDOWN"
    case ENETUNREACH: return "ENETUNREACH"
    case EHOSTDOWN: return "EHOSTDOWN"
    case EHOSTUNREACH: return "EHOSTUNREACH"
    case EAUTH: return "EAUTH"
    case -128: return "userCanceledErr"
    case -5045: return "ENETFSPWDNEEDSCHANGE"
    case -5046: return "ENETFSPWDPOLICY"
    case -5999: return "ENETFSACCOUNTRESTRICTED"
    case -5998: return "ENETFSNOSHARESAVAIL"
    case -5997: return "ENETFSNOAUTHMECHSUPP"
    case -5996: return "ENETFSNOPROTOVERSSUPP"
    default: return nil
    }
  }

  /// Splits an SMB login into domain and user name. Accepts the Windows
  /// form "DOMAIN\user", the smbfs form "DOMAIN;user" and the UPN form
  /// "user@domain" (split at the last "@"). Without a domain, or when one
  /// side of the separator is empty, `domain` is nil and `user` is the input.
  static func smbLoginParts(_ username: String) -> (domain: String?, user: String) {
    if let separator = username.firstIndex(where: { $0 == "\\" || $0 == ";" }) {
      let domain = String(username[..<separator])
      let user = String(username[username.index(after: separator)...])
      if !domain.isEmpty, !user.isEmpty { return (domain, user) }
    } else if let at = username.lastIndex(of: "@") {
      let user = String(username[..<at])
      let domain = String(username[username.index(after: at)...])
      if !domain.isEmpty, !user.isEmpty { return (domain, user) }
    }
    return (nil, username)
  }

  /// Maps a failed NetFS / errno status to a readable message: the cause,
  /// what to check, and the original code as detail ("Error code: 80
  /// (EAUTH)"). `localize` is replaceable so tests are independent of the
  /// system language.
  static func netFSErrorMessage(
    _ status: Int32, share: NetworkShare, mountPoint: String,
    homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
    localize: (String) -> String = { NSLocalizedString($0, comment: "Network share mount error") }
  ) -> String {
    func text(_ key: String, _ arguments: CVarArg...) -> String {
      String(format: localize(key), arguments: arguments)
    }
    // How the user name was understood, or how to give a domain.
    var loginHint: String? {
      guard share.shareProtocol == .smb, !share.username.isEmpty else { return nil }
      let login = smbLoginParts(share.username)
      if let domain = login.domain {
        return text("MountMate tried to sign in as “%@” in the domain “%@”.", login.user, domain)
      }
      return localize(
        "If the account belongs to a Windows domain, enter the username as DOMAIN\\user or user@domain."
      )
    }
    let details: String = {
      if let name = netFSStatusName(status) {
        return text("Error code: %d (%@)", status, name)
      }
      return text("Error code: %d", status)
    }()
    func message(_ paragraphs: String?...) -> String {
      (paragraphs.compactMap { $0 } + [details]).joined(separator: "\n\n")
    }

    switch status {
    case EAUTH:
      return message(
        text("Authentication failed for “%@”. Check the username and password.", share.name),
        loginHint)
    case -128:  // userCanceledErr: NetFS wanted to ask for a login
      return message(
        text(
          "The server “%@” requires a username and password. Enter them in the share’s settings.",
          share.server))
    case -5045:  // ENETFSPWDNEEDSCHANGE
      return message(
        text(
          "The password for “%@” has expired or must be changed. Change it on the server (for example by signing in on a Windows PC of the domain), then enter the new password in MountMate.",
          share.name))
    case -5046:  // ENETFSPWDPOLICY
      return message(
        text(
          "The server rejected the password for “%@” because of its password policy. Ask the server’s administrator.",
          share.name))
    case -5999:  // ENETFSACCOUNTRESTRICTED
      return message(
        text(
          "The account for “%@” is restricted: it may be locked, disabled or not allowed to sign in at this time. Ask the server’s administrator.",
          share.name))
    case -5997:  // ENETFSNOAUTHMECHSUPP
      return message(
        text(
          "The server “%@” offers no sign-in method this Mac supports. Ask its administrator to allow NTLMv2 or Kerberos sign-in.",
          share.server))
    case -5996:  // ENETFSNOPROTOVERSSUPP
      return message(
        text(
          "The server “%@” supports no protocol version this Mac can use. For SMB, ask its administrator to enable SMB 2 or SMB 3.",
          share.server))
    case ECONNREFUSED:
      return message(
        text(
          "The server “%@” refused the connection. Check that file sharing (%@) is turned on on the server.",
          share.server, share.shareProtocol.displayName))
    case EHOSTUNREACH, EHOSTDOWN, ENETUNREACH, ENETDOWN:
      return message(
        text(
          "Could not connect to the server “%@”. Check that it is turned on and reachable from this network.",
          share.server))
    case ETIMEDOUT:
      return message(
        text(
          "Mounting “%@” timed out. Check that the server is reachable and try again.", share.name))
    case ENOENT:
      return message(
        text("The share “%@” was not found on the server “%@”.", share.sharePath, share.server),
        localize(
          "Check the spelling of the share name; it is the name the server shares, not a folder path on its disk."
        ))
    case -5998:  // ENETFSNOSHARESAVAIL
      return message(
        text("The server “%@” has no shares available to this account.", share.server),
        loginHint)
    case EEXIST:
      return message(
        text(
          "“%@” is already connected, probably under a different server name (for example in Finder). Disconnect it there and try again.",
          share.name))
    case EBUSY:
      return message(text("Another volume is already mounted at “%@”.", mountPoint))
    case EPERM, EACCES:
      if !mountPoint.hasPrefix(homeDirectory + "/") {
        return message(
          mountLocationPermissionMessage(share: share, mountPoint: mountPoint, localize: localize))
      }
      return message(
        text("Access to the share “%@” was denied by the server.", share.name),
        localize("Check that this account is allowed to use the share."),
        loginHint,
        share.shareProtocol == .smb
          ? localize(
            "If it stopped working after a server update, ask the administrator whether the server still accepts SMB 2 or SMB 3 with NTLMv2 sign-in."
          ) : nil)
    default:
      if status > 0, let description = strerror(status) {
        return text(
          "Could not mount “%@”: %@ (error %d).", share.name, String(cString: description), status)
      }
      return text("Could not mount “%@” (error %d).", share.name, status)
    }
  }

  static func mountLocationPermissionMessage(
    share: NetworkShare, mountPoint: String,
    localize: (String) -> String = { NSLocalizedString($0, comment: "Network share mount error") }
  ) -> String {
    String(
      format: localize(
        "Could not mount “%1$@” at “%2$@”.\n\nThe mount location requires administrator privileges. Please use a path within your home folder (e.g., ~/mountmate/%1$@) or leave the Custom Mount Point empty to use the default location."
      ),
      share.name, mountPoint)
  }
}
