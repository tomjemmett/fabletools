#' Forecast reconciliation 
#' 
#' This function allows you to specify the method used to reconcile forecasts
#' in accordance with its key structure.
#' 
#' @param .data A mable.
#' @param ... Reconciliation methods applied to model columns within `.data`.
#' 
#' @examples 
#' if (requireNamespace("fable", quietly = TRUE)) {
#' library(fable)
#' lung_deaths_agg <- as_tsibble(cbind(mdeaths, fdeaths)) %>%
#'   aggregate_key(key, value = sum(value))
#' 
#' lung_deaths_agg %>%
#'   model(lm = TSLM(value ~ trend() + season())) %>%
#'   reconcile(lm = min_trace(lm)) %>% 
#'   forecast()
#' }
#' 
#' @export
reconcile <- function(.data, ...){
  UseMethod("reconcile")
}

#' @rdname reconcile
#' @export
reconcile.mdl_df <- function(.data, ...){
  mutate(.data, ...)
}

#' Minimum trace forecast reconciliation
#' 
#' Reconciles a hierarchy using the minimum trace combination method. The 
#' response variable of the hierarchy must be aggregated using sums. The 
#' forecasted time points must match for all series in the hierarchy (caution:
#' this is not yet tested for beyond the series length).
#' 
#' @param models A column of models in a mable.
#' @param method The reconciliation method to use.
#' @param sparse If TRUE, the reconciliation will be computed using sparse 
#' matrix algebra? By default, sparse matrices will be used if the MatrixM 
#' package is installed.
#' 
#' @seealso 
#' [`reconcile()`], [`aggregate_key()`]
#' 
#' @references 
#' Wickramasuriya, S. L., Athanasopoulos, G., & Hyndman, R. J. (2019). Optimal forecast reconciliation for hierarchical and grouped time series through trace minimization. Journal of the American Statistical Association, 1-45. https://doi.org/10.1080/01621459.2018.1448825 
#' 
#' @export
min_trace <- function(models, method = c("wls_var", "ols", "wls_struct", "mint_cov", "mint_shrink"),
                 sparse = NULL){
  if(is.null(sparse)){
    sparse <- requireNamespace("Matrix", quietly = TRUE)
  }
  structure(models, class = c("lst_mint_mdl", "lst_mdl", "list"),
            method = match.arg(method), sparse = sparse)
}

#' @importFrom utils combn
#' @export
forecast.lst_mint_mdl <- function(object, key_data, 
                                  new_data = NULL, h = NULL,
                                  point_forecast = list(.mean = mean), ...){
  method <- object%@%"method"
  sparse <- object%@%"sparse"
  if(sparse){
    require_package("Matrix")
    require_package("methods")
    as.matrix <- Matrix::as.matrix
    t <- Matrix::t
    diag <- function(x) if(is.vector(x)) Matrix::Diagonal(x = x) else Matrix::diag(x)
    solve <- Matrix::solve
    cov2cor <- Matrix::cov2cor
    rowSums <- Matrix::rowSums
  } else {
    cov2cor <- stats::cov2cor
  }
  
  point_method <- point_forecast
  point_forecast <- list()
  # Get forecasts
  fc <- NextMethod()
  if(length(unique(map(fc, interval))) > 1){
    abort("Reconciliation of temporal hierarchies is not yet supported.")
  }
  fc_dist <- map(fc, function(x) x[[distribution_var(x)]])
  is_normal <- all(map_lgl(fc_dist, function(x) inherits(x[[1]], "dist_normal")))
  
  fc_mean <- as.matrix(invoke(cbind, map(fc_dist, mean)))
  fc_var <- transpose_dbl(map(fc_dist, distributional::variance))
  
  # Compute weights (sample covariance)
  res <- map(object, function(x, ...) residuals(x, ...), type = "response")
  if(length(unique(map_dbl(res, nrow))) > 1){
    # Join residuals by index #199
    res <- unname(as.matrix(reduce(res, full_join, by = "date")[,-1]))
  } else {
    res <- matrix(invoke(c, map(res, `[[`, 2)), ncol = length(object))
  }
  
  # Construct S matrix - ??GA: have moved this here as I need it for Structural scaling
  agg_data <- build_key_data_smat(key_data)
  
  n <- nrow(res)
  covm <- crossprod(stats::na.omit(res)) / n
  if(method == "ols"){
    # OLS
    W <- diag(rep(1L, nrow(covm)))
  } else if(method == "wls_var"){
    # WLS variance scaling
    W <- diag(diag(covm))
  } else if (method == "wls_struct"){
    # WLS structural scaling
    W <- diag(vapply(agg_data$agg,length,integer(1L)))
  } else if (method == "mint_cov"){
    # min_trace covariance
    W <- covm
  } else if (method == "mint_shrink"){
    # min_trace shrink
    tar <- diag(apply(res, 2, compose(crossprod, stats::na.omit))/n)
    corm <- cov2cor(covm)
    xs <- scale(res, center = FALSE, scale = sqrt(diag(covm)))
    xs <- xs[stats::complete.cases(xs),]
    v <- (1/(n * (n - 1))) * (crossprod(xs^2) - 1/n * (crossprod(xs))^2)
    diag(v) <- 0
    corapn <- cov2cor(tar)
    d <- (corm - corapn)^2
    lambda <- sum(v)/sum(d)
    lambda <- max(min(lambda, 1), 0)
    W <- lambda * tar + (1 - lambda) * covm
  } else {
    abort("Unknown reconciliation method")
  }
  
  # Check positive definiteness of weights
  eigenvalues <- eigen(W, only.values = TRUE)[["values"]]
  if (any(eigenvalues < 1e-8)) {
    abort("min_trace needs covariance matrix to be positive definite.", call. = FALSE)
  }
  
  # Reconciliation matrices
  R1 <- cov2cor(W)
  W_h <- map(fc_var, function(var) diag(sqrt(var))%*%R1%*%t(diag(sqrt(var))))
  
  if(sparse){ 
    row_btm <- agg_data$leaf
    row_agg <- seq_len(nrow(key_data))[-row_btm]
    S <- Matrix::sparseMatrix(
      i = rep(seq_along(agg_data$agg), lengths(agg_data$agg)),
      j = vec_c(!!!agg_data$agg),
      x = rep(1, sum(lengths(agg_data$agg))))
    J <- Matrix::sparseMatrix(i = S[row_btm,]@i+1, j = row_btm, x = 1L, 
                              dims = rev(dim(S)))
    U <- cbind(
      Matrix::Diagonal(diff(dim(J))),
      -S[row_agg,,drop = FALSE]
    )
    U <- U[, order(c(row_agg, row_btm)), drop = FALSE]
    Ut <- t(U)
    WUt <- W %*% Ut
    P <- J - J %*% WUt %*% solve(U %*% WUt, U)
    # P <- J - J%*%W%*%t(U)%*%solve(U%*%W%*%t(U))%*%U
  }
  else {
    S <- matrix(0L, nrow = length(agg_data$agg), ncol = max(vec_c(!!!agg_data$agg)))
    S[length(agg_data$agg)*(vec_c(!!!agg_data$agg)-1) + rep(seq_along(agg_data$agg), lengths(agg_data$agg))] <- 1L
    R <- t(S)%*%solve(W)
    P <- solve(R%*%S)%*%R
  }
  
  # Apply to forecasts
  fc_mean <- as.matrix(S%*%P%*%t(fc_mean))
  fc_mean <- split(fc_mean, row(fc_mean))
  if(is_normal){
    fc_var <- map(W_h, function(W) diag(S%*%P%*%W%*%t(P)%*%t(S)))
    fc_dist <- map2(fc_mean, transpose_dbl(map(fc_var, sqrt)), distributional::dist_normal)
  } else {
    fc_dist <- map(fc_mean, distributional::dist_degenerate)
  }
  
  # Update fables
  map2(fc, fc_dist, function(fc, dist){
    dimnames(dist) <- dimnames(fc[[distribution_var(fc)]])
    fc[[distribution_var(fc)]] <- dist
    point_fc <- compute_point_forecasts(dist, point_method)
    fc[names(point_fc)] <- point_fc
    fc
  })
}

bottom_up <- function(models){
  structure(models, class = c("lst_btmup_mdl", "lst_mdl", "list"))
}

#' @importFrom utils combn
#' @export
forecast.lst_btmup_mdl <- function(object, key_data, 
                                   point_forecast = list(.mean = mean), ...){
  # Keep only bottom layer
  S <- build_smat_rows(key_data)
  object <- object[rowSums(S) == 1]
  
  point_method <- point_forecast
  point_forecast <- list()
  # Get base forecasts
  fc <- NextMethod()
  if(length(unique(map(fc, interval))) > 1){
    abort("Reconciliation of temporal hierarchies is not yet supported.")
  }
  
  fc_dist <- map(fc, function(x) x[[distribution_var(x)]])
  is_normal <- all(map_lgl(fc_dist, function(x) inherits(x[[1]], "dist_normal")))
  
  fc_mean <- as.matrix(invoke(cbind, map(fc_dist, mean)))
  fc_var <- transpose_dbl(map(fc_dist, distributional::variance))
  
  # Apply to forecasts
  fc_mean <- as.matrix(S%*%t(fc_mean))
  fc_mean <- split(fc_mean, row(fc_mean))
  if(is_normal){
    fc_var <- map(fc_var, function(W) diag(S%*%diag(W)%*%t(S)))
    fc_dist <- map2(fc_mean, transpose_dbl(map(fc_var, sqrt)), distributional::dist_normal)
  } else {
    fc_dist <- map(fc_mean, distributional::dist_degenerate)
  }
  
  # Update fables
  pmap(list(rep_along(fc_mean, fc[1]), fc_mean, fc_dist), function(fc, point, dist){
    dimnames(dist) <- dimnames(fc[[distribution_var(fc)]])
    fc[[distribution_var(fc)]] <- dist
    point_fc <- compute_point_forecasts(dist, point_method)
    fc[names(point_fc)] <- point_fc
    fc
  })
}

build_smat_rows <- function(key_data){
  row_col <- sym(colnames(key_data)[length(key_data)])
  
  smat <- key_data %>%
    unnest(!!row_col) %>% 
    dplyr::arrange(!!row_col) %>% 
    select(!!expr(-!!row_col))
  
  agg_struc <- group_data(dplyr::group_by_all(as_tibble(map(smat, is_aggregated))))
  
  # key_unique <- map(smat, function(x){
  #   x <- unique(x)
  #   x[!is_aggregated(x)]
  # })
  
  agg_struc$.smat <- map(agg_struc$.rows, function(n) diag(1, nrow = length(n), ncol = length(n)))
  agg_struc <- map(seq_len(nrow(agg_struc)), function(i) agg_struc[i,])
  
  out <- reduce(agg_struc, function(x, y){
    # For now, assume x is aggregated into y somehow
    n_key <- ncol(x)-2
    nm_key <- names(x)[seq_len(n_key)]
    agg_vars <- map2_lgl(x[seq_len(n_key)], y[seq_len(n_key)], `<`)
    
    if(!any(agg_vars)) browser() # Something isn't right
    
    # Match rows between summation matrices
    not_agg <- names(Filter(`!`, y[seq_len(n_key)]))
    cols <- group_data(group_by(smat[x$.rows[[1]][seq_len(ncol(x$.smat[[1]]))],], !!!syms(not_agg)))$.rows
    cols_pos <- unlist(cols)
    cols <- rep(seq_along(cols), map_dbl(cols, length))
    cols[cols_pos] <- cols
    
    x$.rows[[1]] <- c(x$.rows[[1]], y$.rows[[1]])
    x$.smat <- list(rbind(
      x$.smat[[1]],
      y$.smat[[1]][, cols, drop = FALSE]
    ))
    x
  })
  
  smat <- out$.smat[[1]]
  smat[out$.rows[[1]],] <- smat
  
  return(smat)
}

build_key_data_smat <- function(x){
  kv <- names(x)[-ncol(x)]
  agg_shadow <- as_tibble(map(x[kv], is_aggregated))
  grp <- as_tibble(vctrs::vec_group_loc(agg_shadow))
  leaf <- rowSums(grp$key)==0 # This only supports non-aggregated leafs
  x_leaf <- x[grp$loc[[which(leaf)]],]
  idx_leaf <- vec_c(!!!x_leaf$.rows)
  
  grp$match <- lapply(unname(split(grp, seq_len(nrow(grp)))), function(level){
    disagg_col <- which(!vec_c(!!!level$key))
    pos <- vec_match(x_leaf[disagg_col], x[level[["loc"]][[1]],disagg_col])
    # lapply(vec_group_loc(pos)$loc, function(i) idx_leaf[i])
    pos <- vec_group_loc(pos)
    pos$loc[order(pos$key)]
  })
  x$.rows[vec_c(!!!grp$loc)] <- vec_c(!!!grp$match)
  return(list(agg = x$.rows, leaf = idx_leaf))
  # out <- matrix(0L, nrow = nrow(x), ncol = length(idx_leaf))
  # out[nrow(x)*(vec_c(!!!x$.rows)-1) + rep(seq_along(x$.rows), lengths(x$.rows))] <- 1L
  # out
}
