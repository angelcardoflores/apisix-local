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

-- OPTIMIZACIÓN: Leer del OS una sola vez al cargar el plugin (Fase de Init)
local env_client_id     = os.getenv("COF_CLIENT_ID")
local env_client_secret = os.getenv("COF_CLIENT_SECRET")

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
    local client_id     = env_client_id     or conf.client_id
    local client_secret = env_client_secret or conf.client_secret

    -- GUARD: Evita que un nil rompa ngx.escape_uri y cause un Error 500
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
    
    ngx.req.set_body_data(new_body)
    ngx.req.set_header("Content-Type", "application/x-www-form-urlencoded")
    ngx.req.set_header("Content-Length", tostring(#new_body))
end

return _M