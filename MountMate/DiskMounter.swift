//
//  Created by homielab
//

import Foundation
import DiskArbitration

class DiskMounter: ObservableObject {
    @Published var shouldAutoMount: Bool = UserDefaults.standard.bool(forKey: "shouldAutoMount") {
        didSet {
            UserDefaults.standard.set(shouldAutoMount, forKey: "shouldAutoMount")
        }
    }
    
    private var session: DASession?
    
    init() {
        if UserDefaults.standard.object(forKey: "shouldAutoMount") == nil {
            shouldAutoMount = true
        }
        setupDiskArbitration()
    }
    
    private func setupDiskArbitration() {
        session = DASessionCreate(kCFAllocatorDefault)
        guard let session = session else {
            print("Failed to create Disk Arbitration session.")
            return
        }
        
        let mountCallback: DADiskMountApprovalCallback = { (disk, context) -> Unmanaged<DADissenter>? in
            guard let context = context else { return nil }
            let this = Unmanaged<DiskMounter>.fromOpaque(context).takeUnretainedValue()

            if !this.shouldAutoMount {
                if let diskName = DADiskGetBSDName(disk) {
                    print("Auto-mount disabled. Dissenting mount for disk: \(String(cString: diskName))")
                }
                
                let dissenter = DADissenterCreate(
                    kCFAllocatorDefault,
                    DAReturn(kDAReturnNotPermitted),
                    nil
                )
                
                return Unmanaged.passRetained(dissenter)
            }
            
            return nil
        }
        
        let context = Unmanaged.passUnretained(self).toOpaque()
        
        DARegisterDiskMountApprovalCallback(session, nil, mountCallback, context)
        
        DASessionSetDispatchQueue(session, DispatchQueue.main)
    }
}
