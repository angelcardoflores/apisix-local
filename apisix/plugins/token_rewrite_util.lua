-- Utilidades compartidas por los plugins *-token-rewrite (NFV y REP).
-- NO es un plugin: no se registra en config.yaml ni se carga como tal; solo se
-- requiere desde los plugins de token para no duplicar la fontanería.
local _M = {}

-- Devuelve nil si el valor es nil o cadena vacía ("" es truthy en Lua, así que sin
-- esto una variable de entorno definida pero vacía colaría como valor válido).
function _M.non_empty(v)
    if v == nil or v == "" then
        return nil
    end
    return v
end

-- Lee un parámetro de formulario tolerando que venga repetido (tabla) o vacío.
function _M.form_value(post_args, name)
    if not post_args then
        return nil
    end
    local v = post_args[name]
    if type(v) == "table" then
        v = v[1]
    end
    return _M.non_empty(v)
end

-- Construye un body application/x-www-form-urlencoded a partir de una lista ordenada
-- de pares {nombre, valor}, lo fija como cuerpo de la petición y ajusta el Content-Type.
-- Los valores se escapan; los nombres son literales fijos del plugin.
function _M.write_form_body(fields)
    local parts = {}
    for i, f in ipairs(fields) do
        parts[i] = f[1] .. "=" .. ngx.escape_uri(f[2])
    end
    local body = table.concat(parts, "&")

    ngx.req.read_body()
    ngx.req.set_body_data(body)
    ngx.req.set_header("Content-Type", "application/x-www-form-urlencoded")
end

return _M
