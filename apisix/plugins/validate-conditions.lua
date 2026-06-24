local core = require("apisix.core")
local http = require("resty.http")

local plugin_name = "validate-conditions"

local schema = {
    type = "object",
    properties = {
        validation_uri = {
            type    = "string",
            default = "http://farmameterms:8001/check-condiciones"
        }
    }
}

local _M = {
    version  = 0.1,
    priority = 2005,   -- después de extract-soe (2010), antes de nfv-token-rewrite (2000)
    name     = plugin_name,
    schema   = schema,
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

function _M.rewrite(conf, ctx)
    local soe     = ctx.soe_value
    local service = ctx.service_value

    if not soe or not service then
        return 400, { message = "SOE o servicio no encontrado en el contexto" }
    end

    local httpc = http.new()
    local res, err = httpc:request_uri(conf.validation_uri, {
        method  = "GET",
        headers = {
            ["X-SOE"]     = soe,
            ["X-Service"] = service
        },
        timeout = 3000
    })

    if not res then
        return 500, { message = "Error llamando al servicio de validación: " .. (err or "desconocido") }
    end

    if res.status == 403 then
        return 403, { message = "Condiciones no aceptadas para SOE=" .. soe .. " Service=" .. service }
    end

    if res.status ~= 200 then
        return res.status, { message = "Error de validación: " .. res.status }
    end
end

return _M