local M = {}

function M.parse(version)
    local major, minor, patch, rest = version:match("^(%d+)%.(%d+)%.(%d+)(.*)$")
    if not major then
        return nil
    end
    local result = { major, minor, patch }
    for _, number in ipairs(result) do
        if (#number > 1 and number:sub(1, 1) == "0") or #number > 9 then
            return nil
        end
    end
    result.pre = {}
    if rest ~= "" then
        if
            not rest:match("^%-[%w.-]+$")
            or rest:find("..", 1, true)
            or rest:sub(2, 2) == "."
            or rest:sub(-1) == "."
        then
            return nil
        end
        for identifier in rest:sub(2):gmatch("[^.]+") do
            if identifier:match("^%d+$") and #identifier > 1 and identifier:sub(1, 1) == "0" then
                return nil
            end
            result.pre[#result.pre + 1] = identifier
        end
    end
    return result
end

function M.less(a, b)
    local x, y = assert(M.parse(a)), assert(M.parse(b))
    for i = 1, 3 do
        if x[i] ~= y[i] then
            return tonumber(x[i]) < tonumber(y[i])
        end
    end
    if #x.pre == 0 or #y.pre == 0 then
        return #x.pre > 0 and #y.pre == 0
    end
    for i = 1, math.max(#x.pre, #y.pre) do
        local left, right = x.pre[i], y.pre[i]
        if not left or not right then
            return left == nil and right ~= nil
        end
        if left ~= right then
            local ln, rn = left:match("^%d+$"), right:match("^%d+$")
            if ln and rn then
                return #left < #right or (#left == #right and left < right)
            elseif ln or rn then
                return ln ~= nil
            end
            return left < right
        end
    end
    return false
end

function M.from_tags(output, prefix)
    local versions, seen = {}, {}
    for tag in output:gmatch("[^\r\n]+") do
        if tag:sub(1, #prefix) == prefix then
            local version = tag:sub(#prefix + 1)
            if M.parse(version) and not seen[version] then
                versions[#versions + 1] = version
                seen[version] = true
            end
        end
    end
    table.sort(versions, M.less)
    return versions
end

return M
