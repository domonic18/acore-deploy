--[[
守望者荣誉调整（配合 acore-manager 管理后台的荣誉处罚功能）

通道：仅控制台/SOAP（player == nil 判定；游戏内玩家输入一律放行忽略）。
原理：mod-ale 的 ALE_CommandSC 挂在 AllCommandScript::OnTryExecuteCommand，
命令树匹配失败仍会触发 PLAYER_EVENT_ON_COMMAND(42)，本脚本拦截伪命令
wardenhonor 并 return false 吞掉 unknown-command 报错，回执经 SOAP 返回。

命令（经 SOAP 发送，可带前导点）：
  wardenhonor get <name>        查询荣誉（可花费荣誉 + 当日荣誉）
  wardenhonor set <name> <val>  设为指定值（0 即清零；只作用于可花费荣誉）
  wardenhonor sub <name> <val>  扣减指定值（下限 0）

注意：仅对在线玩家生效（按名字取在线 Player 对象）。
热加载：控制台/SOAP 发 `reload ale`。
]]--

print(">>Script: WardenHonor loading...OK")

local PREFIX = "wardenhonor"

local function respond(chatHandler, msg)
    chatHandler:SendSysMessage(msg)
end

local function onCommand(_event, player, text, chatHandler)
    -- 仅控制台/SOAP 通道；游戏内输入放行给正常命令处理
    if player ~= nil then
        return true
    end

    local tokens = {}
    for tok in text:gmatch("%S+") do
        tokens[#tokens + 1] = tok
    end
    -- 剥离可选前导点（TryExecuteCommand 正常已剥，这里兜底）
    local head = (tokens[1] or ""):gsub("^%.", "")
    if head ~= PREFIX then
        return true
    end

    local sub = tokens[2]
    local name = tokens[3]

    if sub == "get" and name and #tokens == 4 then
        local target = GetPlayerByName(name)
        if not target then
            respond(chatHandler, "[warden] player not online: " .. name)
        else
            respond(chatHandler, string.format(
                "[warden] %s honor=%d today=%d",
                name, target:GetHonorPoints(), target:GetTodayHonorPoints()))
        end
        return false
    end

    if (sub == "set" or sub == "sub") and name and #tokens == 5 then
        local value = tonumber(tokens[4])
        if not value or value < 0 or value ~= math.floor(value) then
            respond(chatHandler, "[warden] invalid value: " .. tostring(tokens[4]))
            return false
        end
        value = math.floor(value)

        local target = GetPlayerByName(name)
        if not target then
            respond(chatHandler, "[warden] player not online: " .. name)
            return false
        end

        local old = target:GetHonorPoints()
        if sub == "set" then
            target:SetHonorPoints(value)
        else
            -- sub：防负下限，实际扣 delta
            local newHonor = math.max(0, old - value)
            if newHonor ~= old then
                target:ModifyHonorPoints(newHonor - old)
            end
        end
        respond(chatHandler, string.format(
            "[warden] %s honor adjusted: %d -> %d (%s %d)",
            name, old, target:GetHonorPoints(), sub, value))
        return false
    end

    respond(chatHandler, "[warden] usage: wardenhonor get|set|sub <name> [value]")
    return false
end

RegisterPlayerEvent(42, onCommand)
