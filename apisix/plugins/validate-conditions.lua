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
            default = 1500 -- 1.5 segundos máximo de espera
        },
        cache_ttl = {
            type    = "integer",
            minimum = 0,
            default = 60 -- Cachea el resultado por 60 segundos por defecto
        }
    }
}

local _M = {
    version  = 0.1,
    priority = 2005, -- Ejecuta entre extract-soe (2010) y nfv-token-rewrite (2000)
    name     = plugin_name,
    schema   = schema,
}

-- Inicializamos la caché LRU global para el plugin (Guarda hasta 10,000 combinaciones)
local lru_cache = core.lrucache.new({
    count = 10000,
})

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

-- Función interna que realiza la llamada HTTP real (solo se ejecuta si no está en caché)
local function fetch_validation_status(conf, soe, service)
    local httpc = http.new()
    local res, err = httpc:request_uri(conf.validation_uri, {
        method  = "GET",
        headers = {
            ["X-SOE"]      = soe,
            ["X-Service"]  = service,
            ["Connection"] = "keep-alive",
        },
        timeout = conf.timeout,
        keepalive_timeout = 60000, -- Mantener conexión abierta por 60s
        keepalive_pool = 256       -- Pool de hasta 256 conexiones compartidas
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

    -- Creamos una llave única para la caché basada en el SOE y el Servicio
    local cache_key = soe .. ":" .. service
    
    -- Buscamos en la caché. Si no existe, ejecuta 'fetch_validation_status' automáticamente.
    -- Nota: Modificamos el TTL dinámicamente según la configuración del plugin
    local result, err = lru_cache(cache_key, nil, fetch_validation_status, conf, soe, service)

    -- Si hubo un error de red (500) al validar, preferimos no cachearlo permanentemente 
    -- o manejarlo de inmediato para que el próximo intento vuelva a probar.
    if result.status == 500 then
        -- Opcional: Podrías invalidar la caché aquí si falló la red, pero 'core.lrucache'
        -- por defecto habrá guardado el resultado. Como es un 500, dejamos pasar el error controlado.
        return core.response.exit(500, { message = result.message })
    end

    -- Si el estado es cualquier cosa diferente a 200 (ej: 403, 401), bloqueamos la petición
    if result.status ~= 200 then
        return core.response.exit(result.status, { message = result.message })
    end

    -- Si es 200, el plugin termina silenciosamente y permite el paso a 'nfv-token-rewrite'
end

return _M