local core = require("apisix.core")
local util = require("apisix.plugins.token_rewrite_util")

local plugin_name = "nfv-token-rewrite"

local schema = {
    type = "object",
    properties = {
        -- Fallbacks opcionales si no se quieren usar variables de entorno.
        client_id     = { type = "string" },
        client_secret = { type = "string" },
        scope         = { type = "string" }
    }
}

local _M = {
    version  = 0.1,
    priority = 2000, -- Ejecuta justo después de extract-soe (2010)
    name     = plugin_name,
    schema   = schema,
}

-- Leídos del entorno una sola vez al cargar el plugin (fase de init).
local env_client_id     = os.getenv("COF_CLIENT_ID")
local env_client_secret = os.getenv("COF_CLIENT_SECRET")
local env_scope         = os.getenv("NFV_SCOPE")

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

function _M.rewrite(conf, ctx)
    local soe = ctx.soe_value
    if not soe then
        return core.response.exit(400, { message = "SOE no encontrado en el contexto" })
    end

    -- Entorno primero, configuración del plugin como fallback.
    local client_id     = util.non_empty(env_client_id)     or util.non_empty(conf.client_id)
    local client_secret = util.non_empty(env_client_secret) or util.non_empty(conf.client_secret)
    local scope         = util.non_empty(env_scope)          or util.non_empty(conf.scope)

    if not client_id or not client_secret or not scope then
        core.log.error("nfv-token-rewrite: faltan client_id/client_secret/scope (entorno o config).")
        return core.response.exit(500, { message = "Error de configuración interna en el Gateway" })
    end

    -- NFV usa OAuth 'client_credentials' e identifica la farmacia en 'concof_pharmacy'.
    util.write_form_body({
        { "grant_type",      "client_credentials" },
        { "client_id",       client_id },
        { "client_secret",   client_secret },
        { "scope",           scope },
        { "concof_pharmacy", soe },
    })
end

return _M
