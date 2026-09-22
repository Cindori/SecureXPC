from pathlib import Path
import subprocess, sys
base=Path(sys.argv[1])
out=base/'interruption-race';out.mkdir(exist_ok=True)
source=Path(__file__).resolve().parents[2]
s=(base/'XPCClient.swift').read_text().replace('    private let connectionLock = NSLock()','    public static var _probeAfterValidation: ((XPCClient, ObjectIdentifier) -> Void)?\n    private let connectionLock = NSLock()').replace('                let trusted = self.serverRequirement.trustServer(identity)','                let trusted = self.serverRequirement.trustServer(identity)\n                XPCClient._probeAfterValidation?(self, connectionID)')
s+='''\nextension XPCClient {
    public func _probeInterrupt(_ id: ObjectIdentifier) { handleError(event: XPC_ERROR_CONNECTION_INTERRUPTED, connectionID: id) }
    public func _probeCachedConnection() -> ObjectIdentifier? {
        connectionLock.lock(); defer { connectionLock.unlock() }
        return connection.map(ObjectIdentifier.init)
    }
}
'''
variant=out/'XPCClient.swift';variant.write_text(s)
sources=sorted((source/'Sources/SecureXPC').rglob('*.swift'));sources=[variant if p.name=='XPCClient.swift' else p for p in sources]
r=subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-name','SecureXPC','-emit-module','-emit-module-path',str(out/'SecureXPC.swiftmodule'),'-emit-library','-o',str(out/'libSecureXPC.dylib'),*map(str,sources)],capture_output=True,text=True,timeout=90)
(out/'build.log').write_text(r.stdout+r.stderr);r.check_returncode()
main='''import Foundation
import SecureXPC
import Darwin
final class Weak {weak var value:XPCClient?;init(_ value:XPCClient){self.value=value}}
let server=XPCServer.makeAnonymous()
let route=XPCRoute.named("owned-interruption-race").withMessageType(Int.self).withReplyType(Int.self)
server.registerRoute(route){(n:Int)->Int in n}
server.start()
Task {
 var clients=[Weak](), failures=0, preserved=0, hooks=0
 for n in 0..<100 {
  let client=XPCClient.forEndpoint(server.endpoint);clients.append(Weak(client))
  let lock=NSLock();var intercepted=false;var expected:ObjectIdentifier?
  XPCClient._probeAfterValidation={c,id in
   lock.lock();if intercepted {lock.unlock();return};intercepted=true;lock.unlock()
   hooks+=1
   // Test-only deterministic event at the post-trust/pre-cache boundary.
   c._probeInterrupt(id)
   let done=DispatchSemaphore(value:0)
   c.sendMessage(n,to:route){r in precondition((try? r.get())==n);expected=c._probeCachedConnection();done.signal()}
   precondition(done.wait(timeout:.now()+5) == .success)
   precondition(expected != nil && expected != id)
  }
  do {_ = try await client.sendMessage(n,to:route);fatalError("stale handshake succeeded")}
  catch XPCError.connectionInvalid {failures+=1}
  catch {fatalError("unexpected \\(error)")}
  precondition(client._probeCachedConnection()==expected,"late handshake replaced newer connection")
  let echo=try! await client.sendMessage(n,to:route);precondition(echo==n)
  precondition(client._probeCachedConnection()==expected,"next request had to replace healthy connection")
  preserved+=1;client.invalidate()
 }
 XPCClient._probeAfterValidation=nil
 try! await Task.sleep(nanoseconds:500000000)
 let result:[String:Any]=["interrupted_validated_handshakes":hooks,"old_request_failures":failures,"newer_connections_preserved":preserved,"retained_clients":clients.filter{$0.value != nil}.count]
 print(String(data:try! JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),encoding:.utf8)!);fflush(stdout)
 precondition(hooks==100 && failures==100 && preserved==100 && clients.allSatisfy{$0.value==nil});exit(0)
}
dispatchMain()
'''
(out/'main.swift').write_text(main)
r=subprocess.run(['xcrun','swiftc','-swift-version','5','-I',str(out),'-L',str(out),'-lSecureXPC',str(out/'main.swift'),'-o',str(out/'probe')],capture_output=True,text=True,timeout=30)
(out/'probe-build.log').write_text(r.stdout+r.stderr);r.check_returncode()
r=subprocess.run([str(out/'probe')],capture_output=True,text=True,timeout=30)
(out/'result.txt').write_text(r.stdout+r.stderr);print(r.stdout+r.stderr);r.check_returncode()
