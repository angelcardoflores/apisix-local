local core = require("apisix.core")
local cjson = require("cjson.safe")

local plugin_name = "extract-soe"
local SOE_PATTERN = "((?:14|29)0\\d{3})"

local schema = {
    type = "object",
    properties = {
        param_names = {
            type = "array",
            items = { type = "string" },
            default = { "soe", "idFarmacia", "pharmacy", "pharmacyId", "farmacia" }
        }
    }
}

local _M = {
    version  = 0.1,
    priority = 2010,
    name     = plugin_name,
    schema   = schema,
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

local function is_valid_soe(value)
    if not value then return false end
    if #value ~= 6 then return false end
    return ngx.re.match(value, "^" .. SOE_PATTERN .. "$", "jo") ~= nil
end

local function find_by_names(tbl, names)
    local lower_map = {}
    for k, v in pairs(tbl) do
        lower_map[string.lower(k)] = v
    end
    for _, name in ipairs(names) do
        local candidate = lower_map[string.lower(name)]
        if is_valid_soe(candidate) then
            return candidate
        end
    end
    return nil
end

local function extract_service(uri)
    local m = ngx.re.match(uri, "^/([^/]+)", "jo")
    if m then return m[1] end
    return nil
end

function _M.rewrite(conf, ctx)
    local uri = ngx.var.uri
    local soe_value

    -- 1. Path: buscar el patrón SOE en cualquier parte de la URI
    local m = ngx.re.match(uri, SOE_PATTERN, "jo")
    if m then
        soe_value = m[1]
    end

    -- 2. Query string: probar cada nombre posible
    if not soe_value then
        soe_value = find_by_names(ngx.req.get_uri_args(), conf.param_names)
    end

    -- 3. Body: el más costoso, se deja para el final
    if not soe_value then
        ngx.req.read_body()
        local body_data = ngx.req.get_body_data()

        if body_data then
            -- 3a. Form-urlencoded
            local content_type = ngx.req.get_headers()["Content-Type"] or ""
            if string.find(content_type, "application/x-www-form-urlencoded", 1, true) then
                for key, value in string.gmatch(body_data, "([^&=]+)=([^&]+)") do
                    key   = ngx.unescape_uri(key)
                    value = ngx.unescape_uri(value)
                    if is_valid_soe(value) then
                        local lower_key = string.lower(key)
                        for _, name in ipairs(conf.param_names) do
                            if string.lower(name) == lower_key then
                                soe_value = value
                                break
                            end
                        end
                    end
                    if soe_value then break end
                end
            end

            -- 3b. JSON
            if not soe_value then
                local body_json, _ = cjson.decode(body_data)
                if body_json then
                    soe_value = find_by_names(body_json, conf.param_names)
                end
            end

            -- 3c. Último recurso: escanear el body en crudo
            if not soe_value then
                local mb = ngx.re.match(body_data, SOE_PATTERN, "jo")
                if mb then soe_value = mb[1] end
            end
        end
    end

    if not soe_value then
        return 400, { message = "No se ha podido extraer el SOE de la petición" }
    end

    local service_value = extract_service(uri)
    if not service_value then
        return 400, { message = "No se ha podido extraer el servicio de la URI" }
    end

    -- Dejar en contexto para validate-conditions y otros plugins
    ctx.soe_value     = soe_value
    ctx.service_value = service_value
end

return _M