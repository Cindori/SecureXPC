import Foundation
import SecureXPC
import Darwin
final class WeakClient { weak var value:XPCClient?; init(_ value:XPCClient) { self.value=value } }
final class Counter {
    let lock=NSLock();var n=0
    func add(){lock.lock();n+=1;lock.unlock()}
    var value:Int {lock.lock();defer{lock.unlock()};return n}
}
func portCount()->UInt32 {
    var names:mach_port_name_array_t?,types:mach_port_type_array_t?
    var nc:mach_msg_type_number_t=0,tc:mach_msg_type_number_t=0
    precondition(mach_port_names(mach_task_self_,&names,&nc,&types,&tc)==KERN_SUCCESS)
    if let names {vm_deallocate(mach_task_self_,vm_address_t(UInt(bitPattern:names)),vm_size_t(nc)*4)}
    if let types {vm_deallocate(mach_task_self_,vm_address_t(UInt(bitPattern:types)),vm_size_t(tc)*4)}
    return nc
}
func record(_ phase:String,_ info:[String:Any]){var d=info;d["phase"]=phase;d["ports"]=portCount();print(String(data:try! JSONSerialization.data(withJSONObject:d,options:[.sortedKeys]),encoding:.utf8)!);fflush(stdout)}
let server=XPCServer.makeAnonymous()
let route=XPCRoute.named("owned-echo").withMessageType(Int.self).withReplyType(Int.self)
let routeCalls=Counter()
server.registerRoute(route){(n:Int)->Int in routeCalls.add();return n}
let sequence=XPCRoute.named("owned-sequence").withMessageType(Int.self).withSequentialReplyType(Int.self)
server.registerRoute(sequence){(n:Int,p:SequentialResultProvider<Int>) in for v in 0..<100{p.success(value:v)};p.finished()}
let held=XPCRoute.named("owned-held").withSequentialReplyType(Int.self)
let providerLock=NSLock();var providers=[SequentialResultProvider<Int>]()
server.registerRoute(held){(p:SequentialResultProvider<Int>) in providerLock.lock();providers.append(p);providerLock.unlock();p.success(value:1)}
server.start()
let mode=CommandLine.arguments[1]
Task {
    if mode=="cycles" {
        var clients=[WeakClient]()
        record("start",[:])
        for n in 0..<1000 {
            do {let c=XPCClient.forEndpoint(server.endpoint);clients.append(WeakClient(c));let r=try await c.sendMessage(n,to:route);precondition(r==n);c.invalidate();c.invalidate()}catch{fatalError("\(error)")}
            if n==99 || n==499 || n==999 {try! await Task.sleep(nanoseconds:100_000_000);record("\(n+1)-swap-invalidates",["retained":clients.filter{$0.value != nil}.count])}
        }
        try! await Task.sleep(nanoseconds:500_000_000);record("cycles-final",["retained":clients.filter{$0.value != nil}.count,"echoes":routeCalls.value])
    } else if mode=="sequences" {
        let done=DispatchGroup(),values=Counter(),finishes=Counter(),errors=Counter();var clients=[WeakClient]()
        for n in 0..<200 {
            done.enter();autoreleasepool {let c=XPCClient.forEndpoint(server.endpoint);clients.append(WeakClient(c));c.sendMessage(n,to:sequence){result in switch result{case .success:values.add();case .finished:finishes.add();done.leave();case .failure:errors.add();done.leave()}}}
        }
        let completed=done.wait(timeout:.now()+10) == .success
        record("callback-only-before-invalidate",["completed":completed,"values":values.value,"finishes":finishes.value,"errors":errors.value,"retained":clients.filter{$0.value != nil}.count])
        for weak in clients {weak.value?.invalidate()}
        try! await Task.sleep(nanoseconds:500_000_000);record("callback-only-after-invalidate",["retained":clients.filter{$0.value != nil}.count])
    } else if mode=="held" {
        let first=DispatchGroup(),terminal=DispatchGroup(),values=Counter(),failures=Counter(),finishes=Counter();var clients=[WeakClient]()
        for _ in 0..<100 {first.enter();terminal.enter();autoreleasepool {let c=XPCClient.forEndpoint(server.endpoint);clients.append(WeakClient(c));c.send(to:held){result in switch result {case .success:values.add();first.leave();case .failure:failures.add();terminal.leave();case .finished:finishes.add();terminal.leave()}}}}
        precondition(first.wait(timeout:.now()+10) == .success)
        for weak in clients{weak.value?.invalidate();weak.value?.invalidate()}
        let completed=terminal.wait(timeout:.now()+10) == .success
        try! await Task.sleep(nanoseconds:500_000_000);record("held-sequence-invalidation",["completed":completed,"values":values.value,"failures":failures.value,"finishes":finishes.value,"retained":clients.filter{$0.value != nil}.count])
        providerLock.lock();providers.removeAll();providerLock.unlock()
        try! await Task.sleep(nanoseconds:500_000_000);record("held-after-server-provider-release",[:])
    } else if mode=="races" {
        let done=DispatchGroup(),callbacks=Counter(),futureFailures=Counter();var clients=[WeakClient]()
        for n in 0..<1000 {
            autoreleasepool {let c=XPCClient.forEndpoint(server.endpoint);clients.append(WeakClient(c))
                for _ in 0..<2 {
                    done.enter()
                    if n % 2 == 0 { c.sendMessage(n,to:route){_ in callbacks.add();done.leave()} }
                    else { DispatchQueue.global().async{c.sendMessage(n,to:route){_ in callbacks.add();done.leave()}} }
                }
                c.invalidate()
                done.enter();c.sendMessage(n,to:route){r in if case .failure(.connectionInvalid)=r{futureFailures.add()};callbacks.add();done.leave()}
            }
        }
        let completed=done.wait(timeout:.now()+10) == .success
        try! await Task.sleep(nanoseconds:500_000_000);record("handshake-invalidate-races",["completed":completed,"callbacks":callbacks.value,"future_failures":futureFailures.value,"retained":clients.filter{$0.value != nil}.count,"server_calls":routeCalls.value,"requests_started_before_invalidate":1000])
    } else if mode=="security" {
        let done=DispatchGroup(),errors=Counter();var clients=[WeakClient]()
        for n in 0..<100 {done.enter();autoreleasepool{let c=XPCClient.forEndpoint(server.endpoint,withServerRequirement:try! .teamIdentifier("ZZZZZZZZZZ"));clients.append(WeakClient(c));c.sendMessage(n,to:route){r in if case .failure(.insecure)=r{errors.add()};done.leave()}}}
        let completed=done.wait(timeout:.now()+10) == .success
        try! await Task.sleep(nanoseconds:500_000_000);record("untrusted-server",["completed":completed,"insecure":errors.value,"server_calls":routeCalls.value,"retained":clients.filter{$0.value != nil}.count])
    }
    exit(0)
}
dispatchMain()
