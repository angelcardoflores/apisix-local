local core = require("apisix.core")
local util = require("apisix.plugins.token_rewrite_util")

local plugin_name = "rep-token-rewrite"

local schema = {
    type = "object",
    properties = {
        -- Fallbacks opcionales si no se quieren usar variables de entorno.
        username    = { type = "string" },
        password    = { type = "string" },
        scope       = { type = "string" },
        application = { type = "string" }
    }
}

local _M = {
    version  = 0.1,
    priority = 2000, -- Igual que nfv-token-rewrite: tras extract-soe (2010) y validate-conditions (2005)
    name     = plugin_name,
    schema   = schema,
}

-- Leídos del entorno una sola vez al cargar el plugin.
-- Credenciales: las MISMAS que NFV (COF_*), pero en REP se envían como username/password.
local env_username    = os.getenv("COF_CLIENT_ID")
local env_password    = os.getenv("COF_CLIENT_SECRET")
local env_scope       = os.getenv("REP_SCOPE")
local env_application = os.getenv("REP_APPLICATION")

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

function _M.rewrite(conf, ctx)
    local soe = ctx.soe_value
    if not soe then
        return core.response.exit(400, { message = "SOE no encontrado en el contexto" })
    end

    -- Credenciales y scope: los ponemos nosotros (entorno, con fallback a config).
    local username = util.non_empty(env_username) or util.non_empty(conf.username)
    local password = util.non_empty(env_password) or util.non_empty(conf.password)
    local scope    = util.non_empty(env_scope)    or util.non_empty(conf.scope)

    -- 'application' se CONSERVA del request original del cliente (identifica su software);
    -- solo si el cliente no lo manda usamos el valor por defecto (env/config).
    ngx.req.read_body()
    local post_args = ngx.req.get_post_args()
    local application = util.form_value(post_args, "application")
        or util.non_empty(env_application)
        or util.non_empty(conf.application)

    if not username or not password or not scope or not application then
        core.log.error("rep-token-rewrite: faltan username/password/scope/application.")
        return core.response.exit(500, { message = "Error de configuración interna en el Gateway" })
    end

    -- REP usa OAuth 'password grant' e identifica la farmacia en 'pharmacy'.
    util.write_form_body({
        { "grant_type",  "password" },
        { "username",    username },
        { "password",    password },
        { "scope",       scope },
        { "application", application },
        { "pharmacy",    soe },
    })
end

return _M
