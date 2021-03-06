#' Estimation of Linear Mixed Model with Lasso Penalty
#'
#' @description \code{lmmlasso} estimates the linear mixed model with lasso
#'   penalty
#'
#' @seealso \code{\link{ggmix}}
#' @param ggmix_object A ggmix_object object of class \code{lowrank} or
#'   \code{fullrank}
#' @inheritParams ggmix
#' @param n_design total number of observations
#' @param p_design number of variables in the design matrix, excluding the
#'   intercept column
#' @param ... Extra parameters. Currently ignored.
#' @return A object of class \code{ggmix}
#' @export
lmmlasso <- function(ggmix_object, ...) UseMethod("lmmlasso")

#' @rdname lmmlasso
lmmlasso.default <- function(ggmix_object, ...) {
  stop(strwrap("This function should be used with a ggmix object of class
               lowrank or fullrank"))
}


#' @rdname lmmlasso
lmmlasso.fullrank <- function(ggmix_object,
                              ...,
                              penalty.factor,
                              lambda,
                              lambda_min_ratio,
                              nlambda,
                              n_design,
                              p_design,
                              eta_init,
                              maxit,
                              fdev,
                              standardize,
                              alpha, # elastic net mixing param. 1 is lasso, 0 is ridge
                              thresh_glmnet, # this is for glmnet
                              epsilon, # this is for ggmix
                              verbose) {


  # get lambda sequence -----------------------------------------------------

  lamb <- lambdalasso(ggmix_object,
    penalty.factor = penalty.factor,
    nlambda = nlambda,
    lambda_min_ratio = lambda_min_ratio,
    eta_init = eta_init,
    epsilon = epsilon
  )

  lambda_max <- lamb$sequence[[1]]

  lamb$sequence[[1]] <- .Machine$double.xmax


  # create matrix to store results ------------------------------------------

  tuning_params_mat <- matrix(lamb$sequence, nrow = 1, ncol = nlambda, byrow = T)
  dimnames(tuning_params_mat)[[1]] <- list("lambda")
  dimnames(tuning_params_mat)[[2]] <- paste0("s", seq_len(nlambda))
  lambda_names <- dimnames(tuning_params_mat)[[2]]

  coefficient_mat <- matrix(
    nrow = p_design + 3,
    ncol = nlambda,
    dimnames = list(
      c(
        colnames(ggmix_object[["x"]]),
        "eta", "sigma2"
      ),
      lambda_names
    )
  )

  out_print <- matrix(NA,
    nrow = nlambda, ncol = 4,
    dimnames = list(
      lambda_names,
      c(
        "Df",
        "%Dev",
        # "Deviance",
        "Lambda",
        # "saturated_loglik",
        "loglik"
        # "intercept_loglik",
        # "converged"
      )
    )
  )

  # pb <- progress::progress_bar$new(
  #   format = "  fitting over all tuning parameters [:bar] :percent eta: :eta",
  #   total = nlambda, clear = FALSE, width = 90)
  # pb$tick(0)


  # initialize parameters ---------------------------------------------------

  # this includes the intercept
  beta_init <- matrix(0, nrow = p_design + 1, ncol = 1)

  sigma2_init <- sigma2lasso(ggmix_object,
    n = n_design,
    eta = eta_init,
    beta = beta_init
  )


  # lambda loop -------------------------------------------------------------

  for (LAMBDA in lambda_names) {
    lambda_index <- which(LAMBDA == lambda_names)
    lambda <- tuning_params_mat["lambda", LAMBDA][[1]]

    if (verbose >= 1) {
      message(sprintf(
        "Index: %g, lambda: %0.4f",
        lambda_index, if (lambda_index == 1) lambda_max else lambda
      ))
    }

    # iteration counter
    k <- 0

    # to enter while loop
    converged <- FALSE

    while (!converged && k < maxit) {
      Theta_init <- c(as.vector(beta_init), eta_init, sigma2_init)

      # observation weights
      di <- 1 + eta_init * (ggmix_object[["D"]] - 1)
      wi <- (1 / sigma2_init) * (1 / di)


      # fit beta --------------------------------------------------------------
      beta_next_fit <- glmnet::glmnet(
        x = ggmix_object[["x"]],
        y = ggmix_object[["y"]],
        family = "gaussian",
        weights = wi,
        alpha = alpha,
        penalty.factor = c(0, penalty.factor),
        standardize = FALSE,
        intercept = FALSE,
        lambda = c(.Machine$double.xmax, lambda),
        thresh = thresh_glmnet
      )

      beta_next <- beta_next_fit$beta[, 2, drop = FALSE]

      # fit eta ---------------------------------------------------------------
      eta_next <- stats::optim(
        par = eta_init,
        fn = fn_eta_lasso_fullrank,
        gr = gr_eta_lasso_fullrank,
        method = "L-BFGS-B",
        control = list(fnscale = 1),
        lower = 0.01,
        upper = 0.99,
        sigma2 = sigma2_init,
        beta = beta_next,
        eigenvalues = ggmix_object[["D"]],
        x = ggmix_object[["x"]],
        y = ggmix_object[["y"]],
        nt = n_design
      )$par

      # fit sigma2 -----------------------------------------------------------
      sigma2_next <- sigma2lasso(ggmix_object,
        n = n_design,
        beta = beta_next,
        eta = eta_next
      )

      Theta_next <- c(as.vector(beta_next), eta_next, sigma2_next)
      criterion <- crossprod(Theta_next - Theta_init)
      converged <- (criterion < epsilon)[1, 1]

      if (verbose >= 2) {
        message(sprintf(
          "Iteration: %f, Criterion: %f", k, criterion
        ))
      }

      k <- k + 1

      beta_init <- beta_next
      eta_init <- eta_next
      sigma2_init <- sigma2_next
    }

    if (!converged) {
      message(sprintf(
        "algorithm did not converge for lambda %s",
        LAMBDA
      ))
    }

    # a parameter for each observation
    saturated_loglik <- logliklasso(ggmix_object,
      eta = eta_next,
      sigma2 = sigma2_next,
      beta = 1,
      nt = n_design,
      x = ggmix_object[["y"]]
    )

    # intercept only model
    intercept_loglik <- logliklasso(ggmix_object,
      eta = eta_next,
      sigma2 = sigma2_next,
      beta = beta_next[1, , drop = FALSE],
      nt = n_design,
      x = ggmix_object[["x"]][, 1, drop = FALSE]
    )

    # model log lik
    model_loglik <- logliklasso(ggmix_object,
      eta = eta_next,
      sigma2 = sigma2_next,
      beta = beta_next,
      nt = n_design
    )
    # print(model_loglik)

    deviance <- 2 * (saturated_loglik - model_loglik)
    nulldev <- 2 * (saturated_loglik - intercept_loglik)
    devratio <- 1 - deviance / nulldev

    # the minus 1 is because our intercept is actually the first coefficient
    # that shows up in the glmnet solution. the +2 is for the two variance parameters
    df <- length(glmnet::nonzeroCoef(beta_next)) - 1 + 2

    # bic_lambda <- bic(eta = eta_next, sigma2 = sigma2_next, beta = beta_next,
    #                   eigenvalues = ggmix_object[["D"]], x = ggmix_object[["x"]], y = ggmix_object[["y"]], nt = n_design,
    #                   c = an, df_lambda = df)

    # kkt_lambda <- kkt_check(eta = eta_next, sigma2 = sigma2_next, beta = beta_next,
    #                         eigenvalues = ggmix_object[["D"]], x = ggmix_object[["x"]], y = ggmix_object[["y"]], nt = n_design,
    #                         lambda = lambda, tol.kkt = tol.kkt)

    out_print[LAMBDA, ] <- c(
      if (df == 0) 0 else df,
      devratio,
      # deviance,
      lambda,
      # saturated_loglik,
      model_loglik # ,
      # intercept_loglik,
      # bic_lambda,
      # kkt_lambda,
      # converged
    )

    coefficient_mat[, LAMBDA] <- Theta_next


    # prediction of random effects
    # bi <- drop(eta_next * Phi %*% (y - x %*% beta_next)) / di

    # Phi Inverse (used for prediction of random effects)
    # D_inv <- diag(1 / ggmix_object[["D"]])
    # Phi_inv <- U %*% D_inv %*% t(U)

    # D_tilde_inv <- diag(1 / di)
    # V_inv <- U %*% D_tilde_inv %*% t(U)

    # bi <- as.vector(solve((1 / eta_next) * Phi_inv + V_inv) %*% U %*% D_inv %*% (ggmix_object[["y"]] - ggmix_object[["x"]] %*% beta_next))
    # bi <- as.vector(U %*% diag(1 / (1/di + 1/(eta_next*ggmix_object[["D"]]))) %*% t(U) %*% U %*% D_tilde_inv %*% (ggmix_object[["y"]] - ggmix_object[["x"]] %*% beta_next))

    # predicted values (this contains the intercept)
    # yi_hat <- as.vector(x %*% beta_next) + bi

    # fitted values
    # xbhat <- yi_hat - bi

    # residuals
    # ri <- drop(y) - yi_hat

    # bi <- drop(eta_next * Phi %*% (ggmix_object[["y"]] - ggmix_object[["x"]] %*% beta_next)) / di
    # qqnorm(bi)
    # abline(a = 0, b = 1, col = "red")
    # plot(density(bi))

    # randomeff_mat[,LAMBDA] <- bi
    # fitted_mat[,LAMBDA] <- xbhat
    # predicted_mat[,LAMBDA] <- yi_hat
    # resid_mat[,LAMBDA] <- ri

    deviance_change <- abs((out_print[lambda_index, "%Dev"] -
      out_print[lambda_index - 1, "%Dev"]) /
      out_print[lambda_index, "%Dev"])
    # message(sprintf("Deviance change = %.6f", deviance_change))

    # this check: length(deviance_change) > 0 is for the first lambda since deviance_change returns numeric(0)
    if (length(deviance_change) > 0) {
      if (deviance_change < fdev) break
    }
  }

  # if there is early stopping due to fdev, remove NAs
  out_print <- out_print[stats::complete.cases(out_print), ]

  # get names of lambdas for which a solution was obtained
  lambdas_fit <- rownames(out_print)
  out_print[1, "Lambda"] <- lambda_max

  out <- list(
    result = out_print, # used by gic function
    ggmix_object = ggmix_object,
    n_design = n_design, # used by gic function
    p_design = p_design, # used by gic function
    lambda = out_print[, "Lambda"], # used by gic, predict functions
    coef = methods::as(coefficient_mat[, lambdas_fit, drop = F], "dgCMatrix"), #first row is intercept, last two rows are eta and sigma2
    b0 = coefficient_mat["(Intercept)", lambdas_fit], # used by predict function
    beta = methods::as(coefficient_mat[colnames(ggmix_object[["x"]])[-1],
      lambdas_fit,
      drop = FALSE
    ], "dgCMatrix"), # used by predict function
    df = out_print[lambdas_fit, "Df"],
    eta = coefficient_mat["eta", lambdas_fit, drop = FALSE],
    sigma2 = coefficient_mat["sigma2", lambdas_fit, drop = FALSE],
    nlambda = length(lambdas_fit),
    # randomeff = randomeff_mat[, lambdas_fit, drop = FALSE],
    # fitted = fitted_mat[, lambdas_fit, drop = FALSE],
    # predicted = predicted_mat[, lambdas_fit, drop = FALSE],
    # residuals = resid_mat[, lambdas_fit, drop = FALSE],
    cov_names = colnames(ggmix_object[["x"]]) # , used in predict function, this includes intercept
    # lambda_min = id_min,
    # lambda_min_value = lambda_min
  )

  class(out) <- c(paste0("lasso", attr(ggmix_object, "class")), "ggmix_fit")
  return(out)
}
