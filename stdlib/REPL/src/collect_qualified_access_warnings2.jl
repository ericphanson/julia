const jl = JuliaLowering
function collect_qualified_access_warnings2(current_mod, ast)
    ast isa Expr || return Set()
    st = jl.expr_to_syntaxtree(ast)
    ctx1, ex1 = jl.expand_forms_1(current_mod, st, true, Base.get_world_counter())
    ctx2, ex2 = jl.expand_forms_2(ctx1, ex1)
    ctx3, ex3 = jl.resolve_scopes(ctx2, ex2)
    warnings = Set()
    assignments = Dict{Int, Vector{jl.SyntaxTree}}()
    alias_modules = Dict{Int, Module}()
    non_module_bindings = Set{Int}()

    function symbol_from_leaf(node)
        jl.kind(node) == jl.K"Symbol" || return nothing
        name = get(node, :name_val, nothing)
        name === nothing && return nothing
        return name isa Symbol ? name : Symbol(name)
    end

    function is_getproperty_call(node)
        if jl.kind(node) != jl.K"call" || jl.numchildren(node) < 3
            return false
        end
        f = node[1]
        if jl.kind(f) == jl.K"top"
            return f.name_val == "getproperty"
        elseif jl.kind(f) == jl.K"BindingId"
            binfo = jl.get_binding(ctx3, f)
            return binfo.kind === :global && binfo.name == "getproperty"
        end
        return false
    end

    function collect_assignments!(node)
        node isa jl.SyntaxTree || return
        if jl.kind(node) == jl.K"=" && jl.numchildren(node) == 2
            lhs = node[1]
            rhs = node[2]
            if jl.kind(lhs) == jl.K"BindingId"
                push!(get!(assignments, lhs.var_id, jl.SyntaxTree[]), rhs)
            end
        end
        for child in jl.children(node)
            collect_assignments!(child)
        end
        return
    end

    function module_from_global_binding(binfo)
        binfo.mod === nothing && return nothing
        name = Symbol(binfo.name)
        mod_value = try
            getproperty(binfo.mod, name)
        catch
            return nothing
        end
        return mod_value isa Module ? mod_value : nothing
    end

    function module_from_node_for_alias(node)
        if jl.kind(node) == jl.K"BindingId"
            binfo = jl.get_binding(ctx3, node)
            if binfo.kind === :global
                return module_from_global_binding(binfo)
            end
            return get(alias_modules, binfo.id, missing)
        elseif jl.kind(node) == jl.K"Identifier"
            name = symbol_from_leaf(node)
            name === nothing && return nothing
            mod_value = try
                getproperty(current_mod, name)
            catch
                return nothing
            end
            return mod_value isa Module ? mod_value : nothing
        elseif jl.kind(node) == jl.K"Value"
            val = get(node, :value, nothing)
            return val isa Module ? val : nothing
        end
        return nothing
    end

    function resolve_alias_modules!()
        collect_assignments!(ex3)
        changed = true
        while changed
            changed = false
            for (id, rhs_list) in assignments
                haskey(alias_modules, id) && continue
                id in non_module_bindings && continue
                resolved = nothing
                unresolved = false
                invalid = false
                for rhs in rhs_list
                    rhs_mod = module_from_node_for_alias(rhs)
                    if rhs_mod === missing
                        unresolved = true
                    elseif rhs_mod === nothing
                        invalid = true
                        break
                    elseif resolved === nothing
                        resolved = rhs_mod
                    elseif resolved !== rhs_mod
                        invalid = true
                        break
                    end
                end
                if invalid
                    push!(non_module_bindings, id)
                elseif !unresolved && resolved !== nothing
                    alias_modules[id] = resolved
                    changed = true
                end
            end
        end
        return
    end

    function module_from_binding(node)
        if jl.kind(node) == jl.K"BindingId"
            binfo = jl.get_binding(ctx3, node)
            if binfo.kind === :global
                return module_from_global_binding(binfo)
            end
            return get(alias_modules, binfo.id, nothing)
        elseif jl.kind(node) == jl.K"Identifier"
            name = symbol_from_leaf(node)
            name === nothing && return nothing
            mod_value = try
                getproperty(current_mod, name)
            catch
                return nothing
            end
            return mod_value isa Module ? mod_value : nothing
        else
            return nothing
        end
    end

    function resolve_module_chain(node)
        if is_getproperty_call(node) && jl.kind(node[3]) == jl.K"Symbol"
            parent = resolve_module_chain(node[2])
            parent === nothing && return nothing
            outer_mod, mod = parent
            name = symbol_from_leaf(node[3])
            name === nothing && return nothing
            mod_value = try
                getproperty(mod, name)
            catch
                return nothing
            end
            mod_value isa Module || return nothing
            return (outer_mod, mod_value)
        else
            mod = module_from_binding(node)
            mod === nothing && return nothing
            return (mod, mod)
        end
    end

    function collect!(node)
        node isa jl.SyntaxTree || return
        jl.kind(node) == jl.K"module" && return
        if is_getproperty_call(node) && jl.kind(node[3]) == jl.K"Symbol"
            mods = resolve_module_chain(node[2])
            mods === nothing && return
            outer_mod, mod = mods
            name = symbol_from_leaf(node[3])
            name === nothing && return
            owner = try
                which(mod, name)
            catch
                return
            end
            REPL.has_ancestor(owner, mod) && return
            Base.ispublic(mod, name) && return
            mod === Base && Base.ispublic(Core, name) && return
            push!(warnings, (; outer_mod, mod, owner, name_being_accessed=name))
            return
        end
        for child in jl.children(node)
            collect!(child)
        end
        return
    end

    resolve_alias_modules!()
    collect!(ex3)
    return warnings
end
collect_qualified_access_warnings2(ast) = collect_qualified_access_warnings2(Base.active_module(), ast)
