local core = require("apisix.core")

local plugin_name = "nfv-token-rewrite"

local schema = {
    type = "object",
    properties = {
        client_id     = { type = "string" },
        client_secret = { type = "string" },
        scope         = { type = "string" }
    },
    required = { "scope" }
}

local _M = {
    version  = 0.1,
    priority = 2000, -- Ejecuta justo después de extract-soe (2010)
    name     = plugin_name,
    schema   = schema,
}

-- OPTIMIZACIÓN: Leer del OS una sola vez al cargar el plugin (Fase de Init).
-- NOTA: si se rota el secreto hay que reiniciar APISIX para que se relea.
local env_client_id     = os.getenv("COF_CLIENT_ID")
local env_client_secret = os.getenv("COF_CLIENT_SECRET")

-- Devuelve nil si el valor es nil o cadena vacía. En Lua "" es truthy, así que sin
-- esto una variable de entorno definida pero vacía colaría como credencial válida.
local function non_empty(v)
    if v == nil or v == "" then
        return nil
    end
    return v
end

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

function _M.rewrite(conf, ctx)
    local soe = ctx.soe_value
    if not soe then
        -- Uso de la API nativa de APISIX para salir limpiamente
        return core.response.exit(400, { message = "SOE no encontrado en el contexto" })
    end

    -- Prioriza entorno (ya en caché de memoria) o el fallback de la configuración
    local client_id     = non_empty(env_client_id)     or non_empty(conf.client_id)
    local client_secret = non_empty(env_client_secret) or non_empty(conf.client_secret)

    -- GUARD: Evita mandar credenciales nil/vacías y un Error 500 por nil en escape_uri
    if not client_id or not client_secret then
        core.log.error("Faltan las credenciales 'client_id' o 'client_secret' tanto en entorno como en config.")
        return core.response.exit(500, { message = "Error de configuración interna en el Gateway" })
    end

    local new_body = "grant_type=client_credentials"
        .. "&client_id="       .. ngx.escape_uri(client_id)
        .. "&client_secret="   .. ngx.escape_uri(client_secret)
        .. "&scope="           .. ngx.escape_uri(conf.scope)
        .. "&concof_pharmacy=" .. ngx.escape_uri(soe)

    -- Asegura que el estado del body de Nginx esté inicializado antes de mutarlo
    ngx.req.read_body()

    -- set_body_data hace que nginx recalcule el Content-Length hacia el upstream;
    -- fijarlo a mano sería redundante y podría quedar inconsistente, así que no se toca.
    ngx.req.set_body_data(new_body)
    ngx.req.set_header("Content-Type", "application/x-www-form-urlencoded")
end

return _M
