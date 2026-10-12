-- The stock kernel lacks xt_connbytes. Keep incoming TCP interception limited
-- to SYN/ACK and RST, and detect successful downloads from client TCP ACKs.
function g84_hostkey(desync)
    local key = standard_hostkey(desync)
    if not key then return nil end
    local peer = desync.dis and (desync.outgoing and dis_ipsrc(desync.dis) or dis_ipdst(desync.dis))
    local client = peer and ntop(peer) or 'unknown-client'
    return key .. ((desync.dis and desync.dis.ip6) and '/ipv6/' or '/ipv4/') .. client
end

function g84_success_detector(desync, crec)
    if standard_success_detector(desync, crec) then return true end
    local tcp = desync.dis and desync.dis.tcp
    local server = desync.track and desync.track.pos and desync.track.pos.server
    if desync.outgoing and tcp and bitand(tcp.th_flags, TH_ACK) ~= 0
        and server and server.tcp and server.tcp.seq0 then
        local acknowledged = u32add(tcp.th_ack, -server.tcp.seq0)
        local threshold = tonumber(desync.arg.inseq) or 4096
        if threshold > 0 and acknowledged > threshold and acknowledged < 2147483648 then
            DLOG('g84: server data acknowledged, connection successful')
            return true
        end
    end
    return false
end

function g84_failure_detector(desync, crec)
    if standard_failure_detector(desync, crec) then return true end
    local tcp = desync.dis and desync.dis.tcp
    -- A server closing before a TLS handshake can carry a tiny TLS alert
    -- rather than RST. Do not treat normal short HTTP responses as failures.
    if not desync.outgoing and tcp and desync.track
        and desync.track.l7proto == 'tls' and bitand(tcp.th_flags, TH_FIN) ~= 0
        and pos_get(desync, 's') <= 256 then
        DLOG('g84: server closed before TLS handshake completed')
        return true
    end
    return false
end

function g84_circular(ctx, desync)
    local verdict = circular(ctx, desync)
    local crec = automate_conn_record(desync)
    if crec and crec.nocheck and not crec.failure then
        lua_cutoff(ctx)
    end
    return verdict
end
