local core = require("apisix.core")
local cjson = require("cjson.safe")

local plugin_name = "extract-soe"
-- Núcleo del patrón SOE (código de farmacia): formato provincia(2) + "0" + 3 dígitos.
-- Provincia restringida a las 8 ANDALUZAS: Almería (04), Cádiz (11), Córdoba (14),
-- Granada (18), Huelva (21), Jaén (23), Málaga (29), Sevilla (41). Ej.: 290123.
local SOE_CORE  = "(?:04|11|14|18|21|23|29|41)0\\d{3}"
-- Validación EXACTA de un valor (anclado de inicio a fin)
local SOE_EXACT = "^" .. SOE_CORE .. "$"
-- Escaneo dentro de un texto: exige que el SOE NO esté incrustado en un número
-- mayor (p.ej. evita sacar 140123 de 2024140123). El SOE queda en el grupo 1.
local SOE_SCAN  = "(?<!\\d)(" .. SOE_CORE .. ")(?!\\d)"

local schema = {
    type = "object",
    properties = {
        param_names = {
            type = "array",
            items = { type = "string" },
            default = { "soe", "idFarmacia", "pharmacy", "pharmacyId", "farmacia" }
        },
        -- Nombre fijo del servicio. Se inyecta en el contexto y lo usa
        -- validate-conditions (cabecera X-Service y clave de caché). Antes se
        -- extraía del primer segmento de la URI; ahora es fijo por configuración.
        service = {
            type = "string",
            minLength = 1
        }
    },
    required = { "service" },
    additionalProperties = false
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
    -- Forzamos a string por si el JSON parseó el valor como número
    local str_val = tostring(value)
    if #str_val ~= 6 then return false end
    return ngx.re.match(str_val, SOE_EXACT, "jo") ~= nil
end

-- Optimización: Evita alojar tablas nuevas en memoria (Garbage Collector Friendly)
local function find_by_names(tbl, names)
    if not tbl or type(tbl) ~= "table" then return nil end

    -- 1. Intento rápido: Coincidencia exacta (Caso feliz, O(1) por nombre)
    for _, name in ipairs(names) do
        local val = tbl[name]
        if is_valid_soe(val) then return tostring(val) end
    end

    -- 2. Caída: Coincidencia insensitiva mapeando nombres en minúsculas
    local lowered_names = {}
    for i, name in ipairs(names) do
        lowered_names[i] = string.lower(name)
    end

    for k, v in pairs(tbl) do
        local lower_k = string.lower(k)
        for _, lname in ipairs(lowered_names) do
            if lower_k == lname and is_valid_soe(v) then
                return tostring(v)
            end
        end
    end
    return nil
end

function _M.rewrite(conf, ctx)
    local uri = ngx.var.uri
    local soe_value

    -- 1. Path: buscar un SOE en la URI (anclado para no capturar dígitos incrustados)
    local m = ngx.re.match(uri, SOE_SCAN, "jo")
    if m then
        soe_value = m[1]
    end

    -- 2. Query string
    if not soe_value then
        soe_value = find_by_names(ngx.req.get_uri_args(), conf.param_names)
    end

    -- 3. Body
    if not soe_value then
        local content_type = ngx.req.get_headers()["Content-Type"] or ""

        -- 3a. Form-urlencoded (Uso de API nativa de OpenResty)
        if string.find(content_type, "application/x-www-form-urlencoded", 1, true) then
            ngx.req.read_body()
            local post_args, err = ngx.req.get_post_args()
            if post_args then
                soe_value = find_by_names(post_args, conf.param_names)
            end
        end

        -- 3b y 3c. JSON o Raw Body. Usamos core.request.get_body, que además
        -- cubre el caso de que nginx haya volcado el cuerpo a un fichero temporal.
        if not soe_value then
            local body_data = core.request.get_body()
            if body_data then
                -- 3b. JSON
                if string.find(content_type, "application/json", 1, true) then
                    local body_json, _ = cjson.decode(body_data)
                    if body_json then
                        soe_value = find_by_names(body_json, conf.param_names)
                    end
                end

                -- 3c. Último recurso: escanear el body en crudo (anclado para no
                -- capturar un SOE incrustado en una secuencia de dígitos mayor)
                if not soe_value then
                    local mb = ngx.re.match(body_data, SOE_SCAN, "jo")
                    if mb then soe_value = mb[1] end
                end
            end
        end
    end

    -- Validaciones de salida usando la API de APISIX
    if not soe_value then
        return core.response.exit(400, { message = "No se ha podido extraer el SOE de la petición" })
    end

    -- Servicio fijo desde la configuración del plugin (ya no se extrae de la URI)
    ctx.soe_value     = soe_value
    ctx.service_value = conf.service
end

return _M
