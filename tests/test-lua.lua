-- Mock the nfqws2 native API; load the actual upstream orchestration code.
local bit = require('bit')
bitand = bit.band
TH_ACK, TH_SYN, TH_FIN, TH_RST = 16, 2, 1, 4
VERDICT_PASS = 0
function DLOG() end
DLOG_ERR = DLOG
function u32add(a,b) return (a+b) % 4294967296 end
function dis_ipsrc(d) return d.ip and d.ip.ip_src or d.ip6 and d.ip6.ip6_src end
function dis_ipdst(d) return d.ip and d.ip.ip_dst or d.ip6 and d.ip6.ip6_dst end
function ntop(s)
    if #s == 4 then return string.format('%d.%d.%d.%d',string.byte(s,1,4)) end
    return s -- IPv6 fixtures use already formatted addresses.
end
function host_ip() return nil end
function pos_get() return 0 end
function lua_cutoff() end

dofile('vendor/zapret2-v1.0.4/zapret-auto.lua')
dofile('router/g84-auto.lua')
dofile('scripts/test-g84-auto.lua')

-- Exercise the real circular selector, including duplicate failure accounting,
-- success reset and independent host/client/family records.
function orchestrate() end
function plan_instance_pop(d) d.index=(d.index or 0)+1; return d.plan[d.index] end
function plan_instance_execute(d,v,i) d.selected=tonumber(i.arg.strategy); return v end
function test_failure(d) return d.failed or false end
function test_success(d) return d.succeeded or false end
local function connection(host,client,ipv6,failed,succeeded)
    return {outgoing=true,func_instance='test',dis=ipv6 and {ip6={ip6_src=client}} or {ip={ip_src=client}},
        arg={hostkey='g84_hostkey',fails='2',failure_detector='test_failure',success_detector='test_success'},
        track={hostname=host,lua_state={}},failed=failed,succeeded=succeeded,
        plan={{arg={strategy='1'}},{arg={strategy='2'}},{arg={strategy='3'}}}}
end
local client='\192\168\001\012'
local a=connection('a.test',client,false,true)
circular({},a); assert(a.selected==1)
a.index=0; circular({},a); assert(a.selected==1) -- same failed connection counts once
local b=connection('a.test',client,false,true)
circular({},b); assert(b.selected==2)
for _,c in ipairs({connection('b.test',client,false,true),
    connection('a.test','\192\168\001\013',false,true),
    connection('a.test','::12',true,true)}) do
    circular({},c); assert(c.selected==1)
end
local success=connection('b.test',client,false,false,true)
circular({},success); assert(success.selected==1)
local after=connection('b.test',client,false,true)
circular({},after); assert(after.selected==1) -- success reset the failure counter
print('Upstream rotation and isolation checks passed')
