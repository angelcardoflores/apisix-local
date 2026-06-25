local core = require("apisix.core")
local http = require("resty.http")

local plugin_name = "validate-conditions"

local schema = {
    type = "object",
    properties = {
        validation_uri = {
            type    = "string",
            default = "http://farmameterms:8001/check-condiciones"
        },
        timeout = {
            type    = "integer",
            minimum = 100,
            default = 1500 -- 1.5 segundos máximo de espera (en milisegundos)
        }
    },
    additionalProperties = false
}

local _M = {
    version  = 0.1,
    priority = 2005, -- Ejecuta entre extract-soe (2010) y nfv-token-rewrite (2000)
    name     = plugin_name,
    schema   = schema,
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

-- Pregunta a farmameterms si la farmacia (SOE) tiene aceptadas las condiciones del
-- servicio. SIN caché: se consulta en cada petición, para que el estado sea siempre
-- fresco y APISIX quede stateless. El keepalive es clave aquí: como se llama en cada
-- request, reutilizar la conexión evita el handshake TCP cada vez.
local function fetch_validation_status(conf, soe, service)
    local httpc = http.new()

    -- El timeout DEBE fijarse aquí: request_uri NO admite una opción 'timeout'.
    -- set_timeout fija connect/send/read al mismo valor (en milisegundos).
    httpc:set_timeout(conf.timeout)

    local res, err = httpc:request_uri(conf.validation_uri, {
        method  = "GET",
        headers = {
            ["X-SOE"]      = soe,
            ["X-Service"]  = service,
            ["Connection"] = "keep-alive",
        },
        keepalive_timeout = 60000, -- Mantener conexión abierta por 60s
        keepalive_pool    = 256    -- Pool de hasta 256 conexiones compartidas
    })

    if not res then
        return { status = 500, message = "Error llamando al servicio de validación: " .. (err or "desconocido") }
    end

    if res.status == 200 then
        return { status = 200 }
    elseif res.status == 403 then
        return { status = 403, message = "Condiciones no aceptadas para SOE=" .. soe .. " Service=" .. service }
    else
        return { status = res.status, message = "Error de validación: " .. res.status }
    end
end

function _M.rewrite(conf, ctx)
    local soe     = ctx.soe_value
    local service = ctx.service_value

    if not soe or not service then
        return core.response.exit(400, { message = "SOE o servicio no encontrado en el contexto" })
    end

    -- Sin caché: se pregunta a farmameterms en cada petición.
    local result = fetch_validation_status(conf, soe, service)

    -- Fail-closed ante errores 5xx / caída del validador: bloqueamos la petición.
    if result.status >= 500 then
        return core.response.exit(result.status, { message = result.message })
    end

    -- Cualquier estado distinto de 200 (403 condiciones no aceptadas, 401, etc.) bloquea la petición
    if result.status ~= 200 then
        return core.response.exit(result.status, { message = result.message })
    end

    -- Si es 200, el plugin termina silenciosamente y permite el paso a 'nfv-token-rewrite'
end

return _M
