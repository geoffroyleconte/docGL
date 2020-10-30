function compute_α_dual(v, dir_v)
    n = length(v)
    T = eltype(v)
    if n == 0
        return one(T)
    end
    α = one(T)
    @inbounds @simd for i=1:n
        if dir_v[i] < zero(T)
            α_new = -v[i] * T(0.999) / dir_v[i]
            if α_new < α
                α = α_new
            end
        end
    end
    return α
end

function compute_α_primal(v, dir_v, lvar, uvar)
    n = length(v)
    T = eltype(v)
    α_l, α_u = one(T), one(T)
    @inbounds @simd for i=1:n
        if dir_v[i] > zero(T)
            α_u_new = (uvar[i] - v[i]) * T(0.999) / dir_v[i]
            if α_u_new < α_u
                α_u = α_u_new
            end
        elseif dir_v[i] < zero(T)
            α_l_new = (lvar[i] - v[i]) * T(0.999) / dir_v[i]
            if α_l_new < α_l
                α_l = α_l_new
            end
        end
    end
    return min(α_l, α_u)
end

function compute_μ(x_m_lvar, uvar_m_x, s_l, s_u, nb_low, nb_upp)
    return (s_l' * x_m_lvar + s_u' * uvar_m_x) / (nb_low + nb_upp)
end

function refinement!(J_fact, Δ_xλ, r)
    r = LDLFactorizations.ldiv!(J_fact, r)
    Δ_xλ .-= r
end

function solve_augmented_system_aff!(J_fact, J_augm, LDL, r, Δ_aff, Δ_xλ, rhs, rc, rb, x_m_lvar, uvar_m_x,
                                     s_l, s_u, ilow, iupp,  n_cols, n_rows, n_low)
    T = eltype(Δ_xλ)
    Δ_xλ[1:n_cols] .= .-rc
    Δ_xλ[n_cols+1:end] .= .-rb
    Δ_xλ[ilow] += @views s_l[ilow]
    Δ_xλ[iupp] -= @views s_u[iupp]

    rhs = copy(Δ_xλ)
    Δ_xλ = LDLFactorizations.ldiv!(J_fact, Δ_xλ)
    r = mul!(r, LDL, Δ_xλ)
    r .-= rhs
    rNorm = norm(r, Inf)
    # println("res aff  = ", rNorm)
    c_ref = 0
    while rNorm > sqrt(eps(T)) && c_ref < 2
        refinement!(J_fact, Δ_xλ, r)
        r = mul!(r, LDL, Δ_xλ)
        r .-= rhs
        rNorm = norm(r, Inf)
        # println("res aff after  = ", rNorm)
        c_ref += 1
    end
    Δ_aff[1:n_cols+n_rows] = Δ_xλ
    Δ_aff[n_cols+n_rows+1:n_cols+n_rows+n_low] .= @views .-s_l[ilow] .- s_l[ilow].*Δ_xλ[1:n_cols][ilow]./x_m_lvar
    Δ_aff[n_cols+n_rows+n_low+1:end] .= @views .-s_u[iupp] .+ s_u[iupp].*Δ_xλ[1:n_cols][iupp]./uvar_m_x
    return Δ_aff, rhs, c_ref
end

function solve_augmented_system_cc!(J_fact, J_augm, LDL, r, Δ_cc, Δ_xλ, rhs, Δ_aff, σ, μ, x_m_lvar, uvar_m_x,
                                    rxs_l, rxs_u, s_l, s_u, ilow, iupp, n_cols, n_rows, n_low)
    T = eltype(Δ_xλ)
    rxs_l .= @views (-σ*μ .+ Δ_aff[1:n_cols][ilow].*Δ_aff[n_rows+n_cols+1: n_rows+n_cols+n_low])
    rxs_u .= @views σ*μ .+ Δ_aff[1:n_cols][iupp].*Δ_aff[n_rows+n_cols+n_low+1: end]
    Δ_xλ .= zero(eltype(Δ_xλ))
    Δ_xλ[ilow] .+= rxs_l./x_m_lvar
    Δ_xλ[iupp] .+= rxs_u./uvar_m_x

    rhs = copy(Δ_xλ)
    Δ_xλ = LDLFactorizations.ldiv!(J_fact, Δ_xλ)
    r = mul!(r, LDL, Δ_xλ)
    r .-= rhs
    rNorm = norm(r, Inf)
    # println("res cc  = ", rNorm)
    c_ref = 0
    while rNorm > sqrt(eps(T)) && c_ref < 2
        refinement!(J_fact, Δ_xλ, r)
        r = mul!(r, LDL, Δ_xλ)
        r .-= rhs
        rNorm = norm(r, Inf)
        # println("res cc after  = ", rNorm)
        c_ref += 1
    end
    Δ_cc[1:n_cols+n_rows] = Δ_xλ
    Δ_cc[n_cols+n_rows+1:n_cols+n_rows+n_low] .= @views .-(rxs_l.+s_l[ilow].*Δ_xλ[1:n_cols][ilow])./x_m_lvar
    Δ_cc[n_cols+n_rows+n_low+1:end] .= @views (rxs_u.+s_u[iupp].*Δ_xλ[1:n_cols][iupp])./uvar_m_x
    return Δ_cc, rhs, c_ref
end

function iter_mehrotraPC!(pt :: point{T}, itd :: iter_data{T}, FloatData :: QM_FloatData{T}, IntData :: QM_IntData,
                          res :: residuals{T}, sc :: stop_crit, Δt :: Real, k :: Int, regu :: regularization{T},
                          pad :: preallocated_data{T}, max_iter :: Int, ϵ :: tolerances{T}, start_time :: Real,
                          max_time :: Real, safe :: safety_compt, T0 :: DataType, display :: Bool) where {T<:Real}

    regu.ρ = T(eps(T)^(3/4))
    regu.δ = T(eps(T)^(1/2))
    safe.c_catch = 0
    while k<max_iter && !sc.optimal && !sc.tired # && !small_μ && !small_μ

            # Affine scaling direction
        # itd.tmp_diag .= -regu.ρ
        itd.tmp_diag .= zero(T)
        itd.tmp_diag[IntData.ilow] .-= @views pt.s_l[IntData.ilow] ./ itd.x_m_lvar
        itd.tmp_diag[IntData.iupp] .-= @views pt.s_u[IntData.iupp] ./ itd.uvar_m_x
        itd.J_augm.nzval[view(itd.diagind_J,1:IntData.n_cols)] .= @views itd.tmp_diag .- itd.diag_Q
        Amax = @views norm(itd.J_augm.nzval[itd.diagind_J], Inf)
        if Amax > one(T) / T(eps(T)^(1/3)) / regu.δ && safe.c_pdd < 8
            if (T == Float32 && (T0 == Float64 || T0 == Float128)) || (T == Float64 && T0 == Float128)
                break
            elseif length(IntData.Qrows) > 0 || safe.c_pdd < 3 || T0 == Float128
                safe.c_catch = 0
                safe.c_pdd += 1
                regu.δ /= 10
            # regu.ρ /= 10
            end
        end
        # itd.J_augm.nzval[view(itd.diagind_J, IntData.n_cols+1:IntData.n_rows+IntData.n_cols)] .= regu.δ
        itd.J_fact = LDLFactorizations.ldl_factorize!(Symmetric(itd.J_augm, :U), itd.J_fact,
                                                      Amax, regu.ρ, regu.δ, IntData.n_cols)
        if safe.c_catch >= 4
            break
        end
        # itd.LDL = mul!(itd.LDL, itd.J_fact.L, itd.J_fact.D*itd.J_fact.L')
        # itd.LDL = mul!(itd.LDL, itd.LDL, itd.J_fact.L')
        itd.LDL = itd.J_fact.L*itd.J_fact.D*(itd.J_fact.L')
        permute!(itd.LDL, itd.J_fact.pinv, itd.J_fact.pinv)

        pad.Δ_aff, pad.rhs, c_ref = solve_augmented_system_aff!(itd.J_fact, itd.J_augm, itd.LDL, pad.r,
                                                pad.Δ_aff, pad.Δ_xλ, pad.rhs, res.rc, res.rb,
                                                itd.x_m_lvar, itd.uvar_m_x, pt.s_l, pt.s_u,
                                                IntData.ilow, IntData.iupp, IntData.n_cols, IntData.n_rows,
                                                IntData.n_low)
        # if c_ref == 2 && safe.c_catch < 2
        #     safe.c_catch += 1
        #     # regu.ρ *= 10
        #     regu.δ *= 10
        # end
        α_aff_pri = @views compute_α_primal(pt.x, pad.Δ_aff[1:IntData.n_cols], FloatData.lvar, FloatData.uvar)
        α_aff_dual_l = @views compute_α_dual(pt.s_l[IntData.ilow],
                                             pad.Δ_aff[IntData.n_rows+IntData.n_cols+1:IntData.n_rows+IntData.n_cols+IntData.n_low])
        α_aff_dual_u = @views compute_α_dual(pt.s_u[IntData.iupp],
                                             pad.Δ_aff[IntData.n_rows+IntData.n_cols+IntData.n_low+1:end])
        # alpha_aff_dual_final is the min of the 2 alpha_aff_dual
        α_aff_dual_final = min(α_aff_dual_l, α_aff_dual_u)
        pad.x_m_l_αΔ_aff .= @views itd.x_m_lvar .+ α_aff_pri .* pad.Δ_aff[1:IntData.n_cols][IntData.ilow]
        pad.u_m_x_αΔ_aff .= @views itd.uvar_m_x .- α_aff_pri .* pad.Δ_aff[1:IntData.n_cols][IntData.iupp]
        pad.s_l_αΔ_aff .= @views pt.s_l[IntData.ilow] .+ α_aff_dual_final .*
                            pad.Δ_aff[IntData.n_rows+IntData.n_cols+1: IntData.n_rows+IntData.n_cols+IntData.n_low]
        pad.s_u_αΔ_aff .= @views pt.s_u[IntData.iupp] .+ α_aff_dual_final .*
                            pad.Δ_aff[IntData.n_rows+IntData.n_cols+IntData.n_low+1: end]
        μ_aff = compute_μ(pad.x_m_l_αΔ_aff, pad.u_m_x_αΔ_aff, pad.s_l_αΔ_aff, pad.s_u_αΔ_aff,
                          IntData.n_low, IntData.n_upp)
        σ = (μ_aff / itd.μ)^3

        # corrector and centering step
        pad.Δ_cc, pad.rhs, c_ref = solve_augmented_system_cc!(itd.J_fact, itd.J_augm, itd.LDL, pad.r,
                                              pad.Δ_cc, pad.Δ_xλ, pad.rhs, pad.Δ_aff, σ, itd.μ,
                                              itd.x_m_lvar, itd.uvar_m_x, pad.rxs_l, pad.rxs_u, pt.s_l, pt.s_u,
                                              IntData.ilow, IntData.iupp, IntData.n_cols, IntData.n_rows,
                                              IntData.n_low)
        # if c_ref == 2 && safe.c_catch < 2
        #     safe.c_catch += 1
        #     # regu.ρ *= 10
        #     regu.δ *= 10
        # end
        pad.Δ .= pad.Δ_aff .+ pad.Δ_cc # final direction
        α_pri = @views compute_α_primal(pt.x, pad.Δ[1:IntData.n_cols], FloatData.lvar, FloatData.uvar)
        α_dual_l = @views compute_α_dual(pt.s_l[IntData.ilow],
                                         pad.Δ[IntData.n_rows+IntData.n_cols+1:IntData.n_rows+IntData.n_cols+IntData.n_low])
        α_dual_u = @views compute_α_dual(pt.s_u[IntData.iupp], pad.Δ[IntData.n_rows+IntData.n_cols+IntData.n_low+1: end])
        α_dual_final = min(α_dual_l, α_dual_u)

        # new parameters
        pt.x .= @views pt.x .+ α_pri .* pad.Δ[1:IntData.n_cols]
        pt.λ .= @views pt.λ .+ α_dual_final .* pad.Δ[IntData.n_cols+1: IntData.n_rows+IntData.n_cols]
        pt.s_l[IntData.ilow] .= @views pt.s_l[IntData.ilow] .+ α_dual_final .*
                                  pad.Δ[IntData.n_rows+IntData.n_cols+1: IntData.n_rows+IntData.n_cols+IntData.n_low]
        pt.s_u[IntData.iupp] .= @views pt.s_u[IntData.iupp] .+ α_dual_final .*
                                  pad.Δ[IntData.n_rows+IntData.n_cols+IntData.n_low+1: end]
        res.n_Δx = @views α_pri * norm(pad.Δ[1:IntData.n_cols])
        itd.x_m_lvar .= @views pt.x[IntData.ilow] .- FloatData.lvar[IntData.ilow]
        itd.uvar_m_x .= @views FloatData.uvar[IntData.iupp] .- pt.x[IntData.iupp]

        if zero(T) in itd.x_m_lvar # "security" if x is too close from lvar ou uvar
            for i=1:IntData.n_low
                if itd.x_m_lvar[i] == zero(T)
                    itd.x_m_lvar[i] = eps(T)^2
                end
            end
        end
        if zero(T) in itd.uvar_m_x
            for i=1:IntData.n_upp
                if itd.uvar_m_x[i] == zero(T)
                    itd.uvar_m_x[i] = eps(T)^2
                end
            end
        end

        itd.μ = @views compute_μ(itd.x_m_lvar, itd.uvar_m_x, pt.s_l[IntData.ilow], pt.s_u[IntData.iupp],
                                 IntData.n_low, IntData.n_upp)
        itd.Qx = mul_Qx_COO!(itd.Qx, IntData.Qrows, IntData.Qcols, FloatData.Qvals, pt.x)
        itd.xTQx_2 =  pt.x' * itd.Qx / 2
        itd.ATλ = mul_ATλ_COO!(itd.ATλ, IntData.Arows, IntData.Acols, FloatData.Avals, pt.λ)
        itd.Ax = mul_Ax_COO!(itd.Ax, IntData.Arows, IntData.Acols, FloatData.Avals, pt.x)
        itd.cTx = FloatData.c' * pt.x
        itd.pri_obj = itd.xTQx_2 + itd.cTx + FloatData.c0
        itd.dual_obj = FloatData.b' * pt.λ - itd.xTQx_2 + view(pt.s_l,IntData.ilow)'*view(FloatData.lvar, IntData.ilow) -
                        view(pt.s_u, IntData.iupp)'*view(FloatData.uvar, IntData.iupp) + FloatData.c0
        res.rb .= itd.Ax .- FloatData.b
        res.rc .= itd.ATλ .- itd.Qx .+ pt.s_l .- pt.s_u .- FloatData.c

        # update stopping criterion values:
        itd.pdd = abs(itd.pri_obj - itd.dual_obj ) / (one(T) + abs(itd.pri_obj))
#         rcNorm, rbNorm = norm(rc), norm(rb)
#         xNorm = norm(x)
#         λNorm = norm(λ)
#         optimal = pdd < ϵ_pdd && rbNorm < ϵ_rb * max(1, bNorm + ANorm * xNorm) &&
#                     rcNorm < ϵ_rc * max(1, cNorm + QNorm * xNorm + ANorm * λNorm)
        res.rcNorm, res.rbNorm = norm(res.rc, Inf), norm(res.rb, Inf)
        sc.optimal = itd.pdd < ϵ.pdd && res.rbNorm < ϵ.tol_rb && res.rcNorm < ϵ.tol_rc
        sc.small_Δx, sc.small_μ = res.n_Δx < ϵ.Δx, itd.μ < ϵ.μ

        if T == Float32
            k += 1
        elseif T == Float64
            k += 4
        else
            k += 16
        end

        itd.l_pdd[k%6+1] = itd.pdd
        itd.mean_pdd = mean(itd.l_pdd)

        # if regu.δ > regu.δ_min
        #     regu.δ /= 5
        # end
        # if regu.ρ > regu.ρ_min
        #     regu.ρ /= 5
        # end

        Δt = time() - start_time
        sc.tired = Δt > max_time

        if display == true
            @info log_row(Any[k, itd.pri_obj, itd.pdd, res.rbNorm, res.rcNorm, res.n_Δx, α_pri, α_dual_final, itd.μ, regu.ρ, regu.δ])
        end
    end

    return pt, res, itd, Δt, sc, k, regu, safe
end