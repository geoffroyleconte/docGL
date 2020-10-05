module RipQP

using LinearAlgebra, SparseArrays, Statistics, Quadmath

using LDLFactorizations, NLPModels, QuadraticModels, SolverTools

export ripqp

include("starting_points.jl")
include("scaling.jl")
include("sparse_toolbox.jl")
include("iterations.jl")
include("types_toolbox.jl")

function ripqp(QM0; mode = :mono, max_iter=800, ϵ_pdd=1e-8, ϵ_rb=1e-6, ϵ_rc=1e-6,
               tol_Δx=1e-16, ϵ_μ=1e-9, max_time=1200., scaling=true, display=true)

    if mode ∉ [:mono, :multi]
        error("mode should be :mono or :multi")
    end
    start_time = time()
    elapsed_time = 0.0
    QM = SlackModel(QM0)

    # get variables from QuadraticModel
    lvar, uvar = QM.meta.lvar, QM.meta.uvar
    n_cols = length(lvar)
    T = eltype(lvar)
    T0 = T
    Oc = zeros(T, n_cols)
    ilow, iupp = [QM.meta.ilow; QM.meta.irng], [QM.meta.iupp; QM.meta.irng] # finite bounds index
    n_low, n_upp = length(ilow), length(iupp) # number of finite constraints
    irng = QM.meta.irng
    ifix = QM.meta.ifix
    c = grad(QM, Oc)
    A = jac(QM, Oc)
    A = dropzeros!(A)
    Arows, Acols, Avals = findnz(A)
    n_rows, n_cols = size(A)
    @assert QM.meta.lcon == QM.meta.ucon # equality constraint (Ax=b)
    b = QM.meta.lcon
    Q = hess(QM, Oc)  # lower triangular
    Q = dropzeros!(Q)
    Qrows, Qcols, Qvals = findnz(Q)
    c0 = obj(QM, Oc)

    if scaling
        Arows, Acols, Avals, Qrows, Qcols, Qvals,
        c, b, lvar, uvar, d1, d2, d3 = scaling_Ruiz!(Arows, Acols, Avals, Qrows, Qcols, Qvals,
                                                     c, b, lvar, uvar, n_rows, n_cols, T(1.0e-3))
    end
    # cNorm = norm(c)
    # bNorm = norm(b)
    # ANorm = norm(Avals)  # Frobenius norm after scaling; could be computed while scaling?
    # QNorm = norm(Qvals)

    if mode == :multi
        #change types
        T = Float32
        Qvals32, Avals32, c32, c032, b32,
            lvar32, uvar32, ϵ_pdd32, ϵ_rb32, ϵ_rc32,
            tol_Δx32, ϵ_μ32, ρ, δ, ρ_min, δ_min, tmp_diag,
            J_augm, diagind_J, diag_Q, x_m_l_αΔ_aff,
            u_m_x_αΔ_aff, s_l_αΔ_aff, s_u_αΔ_aff, rxs_l,
            rxs_u, Δ_aff, Δ_cc, Δ, Δ_xλ, x, λ, s_l, s_u,
            J_fact, J_P, Qx, ATλ, Ax, x_m_lvar, uvar_m_x,
            xTQx_2,  cTx, pri_obj, dual_obj, μ, pdd,
            rc, rb, rcNorm, rbNorm, tol_rb32, tol_rc32,
            tol_rb, tol_rc, optimal, small_Δx, small_μ,
            l_pdd, mean_pdd, n_Δx = init_params(T, Qrows, Qcols, Qvals,  Arows, Acols, Avals,
                                                c, c0, b, lvar, uvar, tol_Δx, ϵ_μ, ϵ_rb, ϵ_rc,
                                                n_rows, n_cols, ilow, iupp, irng, n_low, n_upp)

    elseif mode == :mono
        # init regularization values
        ρ, δ, ρ_min, δ_min, tmp_diag, J_augm,
            diagind_J, diag_Q, x_m_l_αΔ_aff,
            u_m_x_αΔ_aff, s_l_αΔ_aff, s_u_αΔ_aff,
            rxs_l, rxs_u, Δ_aff, Δ_cc, Δ, Δ_xλ,
            x, λ, s_l, s_u, J_fact, J_P, Qx, ATλ, Ax,
            x_m_lvar, uvar_m_x, xTQx_2,  cTx,
            pri_obj, dual_obj, μ, pdd, rc, rb,
            rcNorm, rbNorm, tol_rb, tol_rc, optimal,
            small_Δx, small_μ,
            l_pdd, mean_pdd, n_Δx = init_params_mono(Qrows, Qcols, Qvals,  Arows, Acols, Avals,
                                                     c, c0, b, lvar, uvar, tol_Δx, ϵ_pdd, ϵ_μ,
                                                     ϵ_rb, ϵ_rc, n_rows, n_cols, ilow, iupp, irng,
                                                     n_low, n_upp)
    end

    Δt = time() - start_time
    tired = Δt > max_time
    k = 0
    c_catch = zero(Int) # to avoid endless loop
    c_pdd = zero(Int) # avoid too small δ_min

    # display
    if display == true
        @info log_header([:k, :pri_obj, :pdd, :rbNorm, :rcNorm, :n_Δx, :α_pri, :α_du, :μ, :ρ, :δ],
        [Int, T, T, T, T, T, T, T, T, T, T, T],
        hdr_override=Dict(:k => "iter", :pri_obj => "obj", :pdd => "rgap",
        :rbNorm => "‖rb‖", :rcNorm => "‖rc‖",
        :n_Δx => "‖Δx‖"))
        @info log_row(Any[k, pri_obj, pdd, rbNorm, rcNorm, n_Δx, zero(T), zero(T), μ, ρ, δ])
    end

    if mode == :multi
        # iters Float 32
        x, λ, s_l, s_u, x_m_lvar, uvar_m_x,
            rc, rb, rcNorm, rbNorm, Qx, ATλ,
            Ax, xTQx_2, cTx, pri_obj, dual_obj,
            pdd, l_pdd, mean_pdd, n_Δx, Δt,
            tired, optimal, μ, k, ρ, δ,
            ρ_min, δ_min, J_augm, J_fact,
            c_catch, c_pdd  = iter_mehrotraPC!(T0, x, λ, s_l, s_u, x_m_lvar, uvar_m_x, lvar32, uvar32,
                                               ilow, iupp, n_rows, n_cols,n_low, n_upp,
                                               Arows, Acols, Avals32, Qrows, Qcols, Qvals32, c032,
                                               c32, b32, rc, rb, rcNorm, rbNorm, tol_rb32, tol_rc32,
                                               Qx, ATλ, Ax, xTQx_2, cTx, pri_obj, dual_obj,
                                               pdd, l_pdd, mean_pdd, n_Δx, small_Δx, small_μ,
                                               Δt, tired, optimal, μ, k, ρ, δ, ρ_min, δ_min,
                                               J_augm, J_fact, J_P, diagind_J, diag_Q, tmp_diag,
                                               Δ_aff, Δ_cc, Δ, Δ_xλ, s_l_αΔ_aff, s_u_αΔ_aff,
                                               x_m_l_αΔ_aff, u_m_x_αΔ_aff, rxs_l, rxs_u,
                                               100, ϵ_pdd32, ϵ_μ32, ϵ_rc32, ϵ_rb32, tol_Δx32,
                                               start_time, max_time, c_catch, c_pdd, display)

        # conversions to Float64
        T = Float64
        x, λ, s_l, s_u, x_m_lvar,
            uvar_m_x, rc, rb,
            rcNorm, rbNorm, Qx,
            ATλ, Ax, xTQx_2, cTx,
            pri_obj, dual_obj, pdd,
            l_pdd, mean_pdd, n_Δx,
            μ, ρ, δ, J_augm, J_P,
            J_fact, Δ_aff, Δ_cc, Δ,
            Δ_xλ, rxs_l, rxs_u, s_l_αΔ_aff,
            s_u_αΔ_aff, x_m_l_αΔ_aff,
            u_m_x_αΔ_aff, diag_Q,
            tmp_diag, ρ_min, δ_min = convert_types!(T, x, λ, s_l, s_u, x_m_lvar, uvar_m_x,
                                                    rc, rb,rcNorm, rbNorm, Qx, ATλ, Ax,
                                                    xTQx_2, cTx, pri_obj, dual_obj, pdd,
                                                    l_pdd, mean_pdd, n_Δx, μ, ρ, δ,
                                                    J_augm, J_P, J_fact, Δ_aff, Δ_cc, Δ,
                                                    Δ_xλ, rxs_l, rxs_u, s_l_αΔ_aff,
                                                    s_u_αΔ_aff, x_m_l_αΔ_aff, u_m_x_αΔ_aff,
                                                    diag_Q, tmp_diag, ρ_min, δ_min)

        optimal = pdd < ϵ_pdd && rbNorm < tol_rb && rcNorm < tol_rc
        small_Δx, small_μ = n_Δx < tol_Δx, μ < ϵ_μ
        ρ /= 10
        δ /= 10

        if T0 == Float128 # iters 64
            Qvals64, Avals64, c64, c064,
                b64, lvar64, uvar64 = convert_data(T, Qvals, Avals, c, c0, b,
                                                    lvar, uvar)
            ϵ_pdd64, ϵ_rb64, ϵ_rc64 = T(1e-3), T(1e-3), T(1e-3)
            tol_rb64, tol_rc64 = ϵ_rb64*(one(T) + rbNorm), ϵ_rc64*(one(T) + rcNorm)
            ρ_min, δ_min = T(sqrt(eps(T))*1e0), T(sqrt(eps(T))*1e0)
            ϵ_μ64, tol_Δx64 = T(1e-10), T(1e-20)

            x, λ, s_l, s_u, x_m_lvar, uvar_m_x,
                rc, rb, rcNorm, rbNorm, Qx, ATλ,
                Ax, xTQx_2, cTx, pri_obj, dual_obj,
                pdd, l_pdd, mean_pdd, n_Δx, Δt,
                tired, optimal, μ, k, ρ, δ,
                ρ_min, δ_min, J_augm, J_fact,
                c_catch, c_pdd  = iter_mehrotraPC!(T0, x, λ, s_l, s_u, x_m_lvar, uvar_m_x, lvar64, uvar64,
                                                   ilow, iupp, n_rows, n_cols,n_low, n_upp,
                                                   Arows, Acols, Avals64, Qrows, Qcols, Qvals64, c064,
                                                   c64, b64, rc, rb, rcNorm, rbNorm, tol_rb64, tol_rc64,
                                                   Qx, ATλ, Ax, xTQx_2, cTx, pri_obj, dual_obj,
                                                   pdd, l_pdd, mean_pdd, n_Δx, small_Δx, small_μ,
                                                   Δt, tired, optimal, μ, k, ρ, δ, ρ_min, δ_min,
                                                   J_augm, J_fact, J_P, diagind_J, diag_Q, tmp_diag,
                                                   Δ_aff, Δ_cc, Δ, Δ_xλ, s_l_αΔ_aff, s_u_αΔ_aff,
                                                   x_m_l_αΔ_aff, u_m_x_αΔ_aff, rxs_l, rxs_u,
                                                   400, ϵ_pdd64, ϵ_μ64, ϵ_rc64, ϵ_rb64, tol_Δx64,
                                                   start_time, max_time, c_catch, c_pdd, display)
            # conversions to Float128
            T = Float128
            x, λ, s_l, s_u, x_m_lvar,
               uvar_m_x, rc, rb,
               rcNorm, rbNorm, Qx,
               ATλ, Ax, xTQx_2, cTx,
               pri_obj, dual_obj, pdd,
               l_pdd, mean_pdd, n_Δx,
               μ, ρ, δ, J_augm, J_P,
               J_fact, Δ_aff, Δ_cc, Δ,
               Δ_xλ, rxs_l, rxs_u, s_l_αΔ_aff,
               s_u_αΔ_aff, x_m_l_αΔ_aff,
               u_m_x_αΔ_aff, diag_Q,
               tmp_diag, ρ_min, δ_min = convert_types!(T, x, λ, s_l, s_u, x_m_lvar, uvar_m_x,
                                                       rc, rb,rcNorm, rbNorm, Qx, ATλ, Ax,
                                                       xTQx_2, cTx, pri_obj, dual_obj, pdd,
                                                       l_pdd, mean_pdd, n_Δx, μ, ρ, δ,
                                                       J_augm, J_P, J_fact, Δ_aff, Δ_cc, Δ,
                                                       Δ_xλ, rxs_l, rxs_u, s_l_αΔ_aff,
                                                       s_u_αΔ_aff, x_m_l_αΔ_aff, u_m_x_αΔ_aff,
                                                       diag_Q, tmp_diag, ρ_min, δ_min)

            optimal = pdd < ϵ_pdd && rbNorm < tol_rb && rcNorm < tol_rc
            small_Δx, small_μ = n_Δx < tol_Δx, μ < ϵ_μ
            ρ /= 10
            δ /= 10
        end
    end

    ρ_min, δ_min = T(sqrt(eps(T0))*1e-5), T(sqrt(eps(T0))*1e0)
    # iters T0
    x, λ, s_l, s_u, x_m_lvar, uvar_m_x,
        rc, rb, rcNorm, rbNorm, Qx, ATλ,
        Ax, xTQx_2, cTx, pri_obj, dual_obj,
        pdd, l_pdd, mean_pdd, n_Δx, Δt,
        tired, optimal, μ, k, ρ, δ,
        ρ_min, δ_min, J_augm, J_fact,
        c_catch, c_pdd  = iter_mehrotraPC!(T0, x, λ, s_l, s_u, x_m_lvar, uvar_m_x, lvar, uvar,
                                           ilow, iupp, n_rows, n_cols,n_low, n_upp,
                                           Arows, Acols, Avals, Qrows, Qcols, Qvals, c0,
                                           c, b, rc, rb, rcNorm, rbNorm, tol_rb, tol_rc,
                                           Qx, ATλ, Ax, xTQx_2, cTx, pri_obj, dual_obj,
                                           pdd, l_pdd, mean_pdd, n_Δx, small_Δx, small_μ,
                                           Δt, tired, optimal, μ, k, ρ, δ, ρ_min, δ_min,
                                           J_augm, J_fact, J_P, diagind_J, diag_Q, tmp_diag,
                                           Δ_aff, Δ_cc, Δ, Δ_xλ, s_l_αΔ_aff, s_u_αΔ_aff,
                                           x_m_l_αΔ_aff, u_m_x_αΔ_aff, rxs_l, rxs_u,
                                           max_iter, ϵ_pdd, ϵ_μ, ϵ_rc, ϵ_rb, tol_Δx,
                                           start_time, max_time, c_catch, c_pdd, display)


    if k>= max_iter
        status = :max_iter
    elseif tired
        status = :max_time
    elseif optimal
        status = :acceptable
    else
        status = :unknown
    end

    if scaling
        x, λ, s_l, s_u, pri_obj,
            rcNorm, rbNorm = post_scale(d1, d2, d3, x, λ, s_l, s_u, rb, rc, rcNorm,
                                        rbNorm, lvar, uvar,ilow, iupp, b, c, c0,
                                        Qrows, Qcols, Qvals, Arows, Acols, Avals,
                                        Qx, ATλ, Ax, cTx, pri_obj, dual_obj, xTQx_2)
    end

    elapsed_time = time() - start_time

    stats = GenericExecutionStats(status, QM, solution = x[1:QM.meta.nvar],
                                  objective = pri_obj,
                                  dual_feas = rcNorm,
                                  primal_feas = rbNorm,
                                  multipliers = λ,
                                  multipliers_L = s_l,
                                  multipliers_U = s_u,
                                  iter = k,
                                  elapsed_time=elapsed_time)
    return stats
end

end