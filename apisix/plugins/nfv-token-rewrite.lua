local core = require("apisix.core")

local plugin_name = "nfv-token-rewrite"

local schema = {
    type = "object",
    properties = {
        client_id     = { type = "string" },
        client_secret = { type = "string" },
        scope         = { type = "string" }
    },
    required = { "client_id", "client_secret", "scope" }
}

local _M = {
    version  = 0.1,
    priority = 2000,
    name     = plugin_name,
    schema   = schema,
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

function _M.rewrite(conf, ctx)
    -- Leer el SOE desde el contexto que dejó extract-soe
    local soe = ctx.soe_value
    if not soe then
        return 400, { message = "SOE no encontrado en contexto, extract-soe debe ejecutarse antes" }
    end

    local new_body = "grant_type=client_credentials"
        .. "&client_id="       .. ngx.escape_uri(conf.client_id)
        .. "&client_secret="   .. ngx.escape_uri(conf.client_secret)
        .. "&scope="           .. ngx.escape_uri(conf.scope)
        .. "&concof_pharmacy=" .. ngx.escape_uri(soe)

    ngx.req.set_body_data(new_body)
    ngx.req.set_header("Content-Type", "application/x-www-form-urlencoded")
    ngx.req.set_header("Content-Length", tostring(#new_body))
end

return _M