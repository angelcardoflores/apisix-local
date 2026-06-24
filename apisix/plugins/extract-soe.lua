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
    -- Forzamos a string por si el JSON parseó el valor como número
    local str_val = tostring(value)
    if #str_val ~= 6 then return false end
    return ngx.re.match(str_val, "^" .. SOE_PATTERN .. "$", "jo") ~= nil
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

-- Lee el cuerpo de forma segura sin importar si está en memoria o en disco
local function get_raw_body()
    ngx.req.read_body()
    local body_data = ngx.req.get_body_data()
    if not body_data then
        local body_file = ngx.req.get_body_file()
        if body_file then
            local f, err = io.open(body_file, "r")
            if f then
                body_data = f:read("*all")
                f:close()
            end
        end
    end
    return body_data
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

        -- 3b y 3c. JSON o Raw Body (Leídos de forma segura)
        if not soe_value then
            local body_data = get_raw_body()
            if body_data then
                -- 3b. JSON
                if string.find(content_type, "application/json", 1, true) then
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
    end

    -- Validaciones de salida usando la API de APISIX
    if not soe_value then
        return core.response.exit(400, { message = "No se ha podido extraer el SOE de la petición" })
    end

    local service_value = extract_service(uri)
    if not service_value then
        return core.response.exit(400, { message = "No se ha podido extraer el servicio de la URI" })
    end

    -- Inyección limpia en el contexto
    ctx.soe_value     = soe_value
    ctx.service_value = service_value
end

return _M