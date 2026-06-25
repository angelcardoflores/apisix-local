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
        },
        cache_ttl = {
            type    = "integer",
            minimum = 0,
            default = 60 -- Segundos que se cachea el resultado (0 = sin caché)
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

-- Versión "normal" de las entradas de caché. Para invalidar una entrada basta con
-- reescribirla con otra versión: el siguiente acceso normal verá el desajuste y
-- volverá a llamar a farmameterms.
local CACHE_VERSION   = "v1"
local INVALID_VERSION = "invalid"

-- IMPORTANTE: en core.lrucache el TTL se fija en el CONSTRUCTOR (opts.ttl), NO en
-- el 2º argumento de la función de caché (ese argumento es una "versión" de
-- invalidación, no un tiempo de vida). Como el TTL es por instancia y aquí debe ser
-- configurable por ruta, creamos y reutilizamos una instancia por cada cache_ttl
-- distinto que aparezca.
local caches = {}
local function get_cache(ttl)
    local cache = caches[ttl]
    if not cache then
        cache = core.lrucache.new({ count = 10000, ttl = ttl })
        caches[ttl] = cache
    end
    return cache
end

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

-- Función interna que realiza la llamada HTTP real (solo se ejecuta si no está en caché)
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

    local cache_key = soe .. ":" .. service

    -- Caché solo si cache_ttl > 0; si no, se pregunta siempre a farmameterms.
    -- Guardamos sobre 'cache' directamente (no un booleano aparte) para que el
    -- análisis estático estreche el tipo a función dentro de los 'if cache then'.
    local cache
    if conf.cache_ttl and conf.cache_ttl > 0 then
        cache = get_cache(conf.cache_ttl)
    end

    local result, err
    if cache then
        -- Busca en la caché; si no existe (o cambió la versión) ejecuta fetch_validation_status.
        result, err = cache(cache_key, CACHE_VERSION, fetch_validation_status, conf, soe, service)

        -- GUARD: si la caché no pudo crear el objeto, evitamos que un nil rompa el acceso a .status
        if not result then
            core.log.error("validate-conditions: resultado nulo de la caché: ", err or "desconocido")
            return core.response.exit(500, { message = "Error interno validando condiciones" })
        end
    else
        -- cache_ttl = 0 -> sin caché: preguntamos siempre a farmameterms
        result = fetch_validation_status(conf, soe, service)
    end

    -- Fail-closed ante errores 5xx / caída del validador: bloqueamos la petición y,
    -- además, invalidamos la entrada para no servir un error cacheado en el próximo intento.
    if result.status >= 500 then
        if cache then
            cache(cache_key, INVALID_VERSION, function() return { status = 0 } end)
        end
        return core.response.exit(result.status, { message = result.message })
    end

    -- Cualquier estado distinto de 200 (403 condiciones no aceptadas, 401, etc.) bloquea la petición
    if result.status ~= 200 then
        return core.response.exit(result.status, { message = result.message })
    end

    -- Si es 200, el plugin termina silenciosamente y permite el paso a 'nfv-token-rewrite'
end

return _M
