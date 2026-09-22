import Foundation
import SecureXPC
import Darwin
struct Payload: Codable {
    let value:Int
    init(_ value:Int){self.value=value}
    enum CodingKeys:String,CodingKey {case value}
    init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        value=try c.decode(Int.self,forKey:.value)
        if value<0 {throw DecodingError.dataCorruptedError(forKey:.value,in:c,debugDescription:"Owned malformed payload")}
    }
}
final class Token {}
final class Weak {weak var value:Token?;init(_ value:Token){self.value=value}}
let lock=NSLock();var values=0,errors=0,finishes=0
let server=XPCServer.makeAnonymous()
let route=XPCRoute.named("owned-malformed").withSequentialReplyType(Payload.self)
var held=[SequentialResultProvider<Payload>]()
server.registerRoute(route){(p:SequentialResultProvider<Payload>) in lock.lock();held.append(p);lock.unlock();p.success(value:.init(1));p.success(value:.init(-1));for _ in 0..<20{p.success(value:.init(2))}}
server.start()
let client=XPCClient.forEndpoint(server.endpoint)
let done=DispatchGroup();var tokens=[Weak]()
for _ in 0..<100 {
    done.enter()
    autoreleasepool {let token=Token();tokens.append(Weak(token));client.send(to:route){[token] result in
        _=token;lock.lock();defer{lock.unlock()}
        switch result {case .success:values+=1;case .failure:errors+=1;done.leave();case .finished:finishes+=1;done.leave()}
    }}
}
func property(_ name:String,of value:Any)->Any?{var mirror:Mirror?=Mirror(reflecting:value);while let m=mirror{if let c=m.children.first(where:{$0.label==name}){return c.value};mirror=m.superclassMirror};return nil}
DispatchQueue.global().async {
    let completed=done.wait(timeout:.now()+10) == .success
    usleep(500000)
    let replies=property("inProgressSequentialReplies",of:client)!
    let registrations=Mirror(reflecting:property("handlers",of:replies)!).children.count
    let result:[String:Any]=["completed":completed,"values":values,"failures":errors,"finishes":finishes,"registered_handlers":registrations,"retained_callback_tokens":tokens.filter{$0.value != nil}.count]
    print(String(data:try! JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),encoding:.utf8)!);fflush(stdout)
    precondition(completed && values==100 && errors==100 && finishes==0 && registrations==0 && tokens.allSatisfy{$0.value==nil})
    client.invalidate();exit(0)
}
dispatchMain()
