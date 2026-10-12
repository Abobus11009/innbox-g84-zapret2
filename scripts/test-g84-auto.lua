-- Run with the project's nfqws2 --intercept=0 after loading the four Lua files.
assert(g84_hostkey({dis={},track={hostname='www.youtube.com'},arg={}}) == 'www.youtube.com/ipv4/unknown-client')
assert(g84_hostkey({dis={ip6={}},track={hostname='www.youtube.com'},arg={}}) == 'www.youtube.com/ipv6/unknown-client')
assert(g84_hostkey({dis={},arg={reqhost=true}}) == nil)
local client_ip, server_ip = '\192\168\001\012', '\142\251\153\004'
local out = {outgoing=true,dis={ip={ip_src=client_ip,ip_dst=server_ip}},track={hostname='www.youtube.com'},arg={}}
local incoming = {outgoing=false,dis={ip={ip_src=server_ip,ip_dst=client_ip}},track={hostname='www.youtube.com'},arg={}}
assert(g84_hostkey(out) == 'www.youtube.com/ipv4/192.168.1.12')
assert(g84_hostkey(out) == g84_hostkey(incoming))
local original_success = standard_success_detector
standard_success_detector = function() return false end
local function packet(ack, seq0, outgoing, flags)
    return {
        outgoing = outgoing,
        arg = { inseq = '4096' },
        dis = { tcp = { th_ack = ack, th_flags = flags or TH_ACK } },
        track = { pos = { server = { tcp = { seq0 = seq0 } } } }
    }
end
assert(g84_success_detector(packet(5100,100,true),{}))
assert(not g84_success_detector(packet(4196,100,true),{}))
assert(not g84_success_detector(packet(5100,100,false),{}))
assert(not g84_success_detector(packet(5100,100,true,TH_SYN),{}))
assert(not g84_success_detector(packet(50,100,true),{}))
assert(g84_success_detector(packet(6000,4294967280,true),{}))
assert(not g84_success_detector({outgoing=true,arg={},dis={}},{}))
local no_track = packet(5100,100,true)
no_track.track = nil
assert(not g84_success_detector(no_track,{}))
standard_success_detector = function() return true end
assert(g84_success_detector({dis={},arg={}},{}))
standard_success_detector = original_success

local original_failure, original_pos = standard_failure_detector, pos_get
standard_failure_detector = function() return false end
local seq = 100
pos_get = function() return seq end
local fin = {outgoing=false,dis={tcp={th_flags=TH_FIN}},track={l7proto='tls'}}
assert(g84_failure_detector(fin,{}))
seq = 1000
assert(not g84_failure_detector(fin,{}))
seq = 100
fin.track.l7proto = 'http'
assert(not g84_failure_detector(fin,{}))
fin.track.l7proto = 'tls'
fin.outgoing = true
assert(not g84_failure_detector(fin,{}))
standard_failure_detector = function() return true end
assert(g84_failure_detector({dis={}},{}))
standard_failure_detector, pos_get = original_failure, original_pos

local original_circular, original_record, original_cutoff = circular, automate_conn_record, lua_cutoff
local record, cutoffs = {}, 0
circular = function() return 17 end
automate_conn_record = function() return record end
lua_cutoff = function() cutoffs = cutoffs + 1 end
assert(g84_circular({}, {}) == 17 and cutoffs == 0)
record = {nocheck=true,failure=true}
g84_circular({}, {})
assert(cutoffs == 0)
record = {nocheck=true}
g84_circular({}, {})
assert(cutoffs == 1)
circular, automate_conn_record, lua_cutoff = original_circular, original_record, original_cutoff
print('G84 adaptive Lua checks passed')
