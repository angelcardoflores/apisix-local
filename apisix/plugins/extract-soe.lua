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
        -- validate-conditions (cabecera X-Service y, antes, clave de caché).
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

-- Fuente 1: el SOE en el path (anclado para no capturar dígitos incrustados).
local function from_path()
    local m = ngx.re.match(ngx.var.uri, SOE_SCAN, "jo")
    if m then return m[1] end
    return nil
end

-- Fuente 2: parámetros con nombre de la query string.
local function from_query(param_names)
    return find_by_names(ngx.req.get_uri_args(), param_names)
end

-- Fuente 3: el body. Primero por nombre de parámetro (form-urlencoded o JSON) y,
-- como último recurso, escaneando el body en crudo. core.request.get_body cubre
-- también el caso de que nginx haya volcado el cuerpo a un fichero temporal.
local function from_body(param_names)
    local content_type = ngx.req.get_headers()["Content-Type"] or ""

    -- 3a. Form-urlencoded (API nativa de OpenResty)
    if string.find(content_type, "application/x-www-form-urlencoded", 1, true) then
        ngx.req.read_body()
        local post_args = ngx.req.get_post_args()
        if post_args then
            local soe = find_by_names(post_args, param_names)
            if soe then return soe end
        end
    end

    local body_data = core.request.get_body()
    if not body_data then return nil end

    -- 3b. JSON: buscar por nombre de campo
    if string.find(content_type, "application/json", 1, true) then
        local body_json = cjson.decode(body_data)
        if body_json then
            local soe = find_by_names(body_json, param_names)
            if soe then return soe end
        end
    end

    -- 3c. Último recurso: escanear el body en crudo (anclado)
    local mb = ngx.re.match(body_data, SOE_SCAN, "jo")
    if mb then return mb[1] end

    return nil
end

function _M.rewrite(conf, ctx)
    -- Se busca el SOE en orden: path -> query -> body. El primero que aparezca gana.
    local soe_value = from_path()
        or from_query(conf.param_names)
        or from_body(conf.param_names)

    if not soe_value then
        return core.response.exit(400, { message = "No se ha podido extraer el SOE de la petición" })
    end

    -- Inyección limpia en el contexto (service es fijo desde la config del plugin).
    ctx.soe_value     = soe_value
    ctx.service_value = conf.service
end

return _M
