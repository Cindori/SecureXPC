import Foundation
import SecureXPC
import Darwin
final class WeakClient { weak var value: XPCClient?; init(_ value: XPCClient) { self.value = value } }
let server = XPCServer.makeAnonymous()
let route = XPCRoute.named("owned-held-sequence").withMessageType(Int.self).withSequentialReplyType(Int.self)
let lock = NSLock()
var providers = [SequentialResultProvider<Int>]()
server.registerRoute(route) { (n: Int, provider: SequentialResultProvider<Int>) in
    lock.lock(); providers.append(provider); lock.unlock()
    provider.success(value:n)
}
let echo = XPCRoute.named("owned-echo").withMessageType(Int.self).withReplyType(Int.self)
server.registerRoute(echo) { (n:Int)->Int in n }
server.start()
// Test-only introspection of this owned client; no shared dependency modifications.
func property(_ name:String, of value:Any) -> Any? {
    var mirror:Mirror? = Mirror(reflecting:value)
    while let m = mirror {
        if let child=m.children.first(where:{$0.label==name}) { return child.value }
        mirror=m.superclassMirror
    }
    return nil
}
func cancelConnection(_ client:XPCClient) {
    let optional=property("connection",of:client)!
    let connection=Mirror(reflecting:optional).children.first!.value as! xpc_connection_t
    xpc_connection_cancel(connection)
}
func handlerCount(_ client:XPCClient)->Int {
    let replies=property("inProgressSequentialReplies",of:client)!
    return Mirror(reflecting:property("handlers",of:replies)!).children.count
}
Task {
    var client:XPCClient?=XPCClient.forEndpoint(server.endpoint)
    let weak=WeakClient(client!)
    var successes=0, terminals=0
    for n in 0..<30 {
        client!.sendMessage(n,to:route) { result in
            lock.lock();defer { lock.unlock() }
            switch result {case .success: successes += 1; case .failure,.finished: terminals += 1}
        }
        for _ in 0..<100 {
            lock.lock();let ready=successes>n;lock.unlock()
            if ready { break }
            try! await Task.sleep(nanoseconds:10_000_000)
        }
        lock.lock();let ready=successes==n+1;lock.unlock();precondition(ready)
        cancelConnection(client!)
        try! await Task.sleep(nanoseconds:30_000_000)
        // A normal new request confirms the same client reconnects after the error.
        let reply=try! await client!.sendMessage(n,to:echo);precondition(reply==n)
    }
    try! await Task.sleep(nanoseconds:300_000_000)
    let result:[String:Any] = ["phase":"30-cancel-reconnect-held-sequences", "values":successes,"terminal_callbacks":terminals,"registered_handlers":handlerCount(client!),"reconnected_echoes":30]
    print(String(data:try! JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),encoding:.utf8)!);fflush(stdout)
    cancelConnection(client!)
    client=nil
    try! await Task.sleep(nanoseconds:500_000_000)
    print("{\"phase\":\"after-final-cancel-and-release\",\"retained_client\":\(weak.value != nil)}");fflush(stdout)
    exit(0)
}
dispatchMain()
