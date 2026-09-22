from pathlib import Path
import subprocess, sys
base=Path(sys.argv[1])
out=base/'controlled-race';out.mkdir(exist_ok=True)
source=Path(__file__).resolve().parents[2]
s=(base/'XPCClient.swift').read_text().replace('    private let connectionLock = NSLock()','    public static var _probeBeforeCachingValidatedConnection: ((XPCClient) -> Void)?\n    private let connectionLock = NSLock()').replace('                let trusted = self.serverRequirement.trustServer(identity)','                let trusted = self.serverRequirement.trustServer(identity)\n                XPCClient._probeBeforeCachingValidatedConnection?(self)')
variant=out/'XPCClient.swift';variant.write_text(s)
sources=sorted((source/'Sources/SecureXPC').rglob('*.swift'));sources=[variant if p.name=='XPCClient.swift' else p for p in sources]
r=subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-name','SecureXPC','-emit-module','-emit-module-path',str(out/'SecureXPC.swiftmodule'),'-emit-library','-o',str(out/'libSecureXPC.dylib'),*map(str,sources)],capture_output=True,text=True,timeout=90)
(out/'build.log').write_text(r.stdout+r.stderr);r.check_returncode()
main='''import Foundation
import SecureXPC
import Darwin
final class Weak {weak var value:XPCClient?;init(_ value:XPCClient){self.value=value}}
let lock=NSLock();var hooks=0,calls=0,errors=0
let server=XPCServer.makeAnonymous()
let route=XPCRoute.named("owned-controlled-race").withReplyType(Int.self)
server.registerRoute(route){()->Int in lock.lock();calls+=1;lock.unlock();return 1}
server.start()
// Instrumentation only: invalidate exactly after successful trust evaluation,
// before withConnection can publish the initialized connection.
XPCClient._probeBeforeCachingValidatedConnection={client in lock.lock();hooks+=1;lock.unlock();client.invalidate()}
let group=DispatchGroup();var clients=[Weak]()
for _ in 0..<1000 {group.enter();autoreleasepool{let c=XPCClient.forEndpoint(server.endpoint);clients.append(Weak(c));c.send(to:route){r in lock.lock();if case .failure(.connectionInvalid)=r{errors+=1};lock.unlock();group.leave()}}}
DispatchQueue.global().async{
let done=group.wait(timeout:.now()+15) == .success
usleep(500000)
let result:[String:Any]=["completed":done,"validated_handshakes_invalidated":hooks,"terminal_errors":errors,"server_calls":calls,"retained_clients":clients.filter{$0.value != nil}.count]
print(String(data:try! JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),encoding:.utf8)!);fflush(stdout)
precondition(done && hooks == 1000 && errors == 1000 && calls == 0 && clients.allSatisfy { $0.value == nil })
exit(0)
}
dispatchMain()
'''
(out/'main.swift').write_text(main)
r=subprocess.run(['xcrun','swiftc','-swift-version','5','-I',str(out),'-L',str(out),'-lSecureXPC',str(out/'main.swift'),'-o',str(out/'probe')],capture_output=True,text=True,timeout=30)
(out/'probe-build.log').write_text(r.stdout+r.stderr);r.check_returncode()
r=subprocess.run([str(out/'probe')],capture_output=True,text=True,timeout=25)
(out/'result.txt').write_text(r.stdout+r.stderr);print(r.stdout+r.stderr);r.check_returncode()
