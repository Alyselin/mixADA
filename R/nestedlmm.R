setClass("FLXcomponentnestedlmm",
         representation(random="list"),
         contains = "FLXcomponent")

setClass("FLXMRnestedlmm",
         representation(family = "character",
                        random = "list",
                        group = "factor",
                        z = "matrix",
                        which = "ANY"),
         contains = "FLXMR")

setClass("FLXMRnestedlmmfix",
         contains = "FLXMRnestedlmm")

FLXMRnestedlmm <- function(formula = . ~ ., random, 
                     varFix = c(Random = FALSE, Residual = FALSE), ...)
{
  family <- "gaussian"
  if (length(varFix) != 2 || is.null(names(varFix)) || any(is.na(pmatch(names(varFix), c("Random", "Residual"))))) 
    stop("varFix has to be a named vector of length two")
  else names(varFix) <- c("Random", "Residual")[pmatch(names(varFix), c("Random", "Residual"))]
  random <- lapply(random, function(ran) if (length(ran) == 3) ran else formula(paste(".", paste(deparse(ran), collapse = ""))))
  object <- new("FLXMRnestedlmm", formula = formula, random = random, 
                weighted = TRUE, family = family, name = "FLXMRnestedlmm:gaussian")
  if (any(varFix)) object <- new("FLXMRnestedlmmfix", object)
  object@preproc.y <- function(x){
    if (ncol(x) > 1)
      stop(paste("y must be univariate"))
    x
  }
  add <- function(x) Reduce("+", x)
  nestedlmm.wfit <- function(x, y, w, z, which, random) {
    effect <- lapply(seq_along(z), function(i)
                     do.call("cbind", z[[i]]) %*% random$beta[[i]])
    W <- rep(w, sapply(x, nrow))
    X <- do.call("rbind", x)
    Y <- do.call("rbind", y)
    Effect <- do.call("rbind", effect)
    fit <- lm.wfit(X, Y - Effect, W, ...)
    XSigmaX <- sapply(seq_along(z), function(i)
                      sum(diag(crossprod(tcrossprod(do.call("cbind", z[[i]]), chol(random$Sigma[[i]]))))))
    wSum <- tapply(w, which, sum)
    sigma2 <- (sum(W*resid(fit)^2) + sum(wSum*XSigmaX))/sum(W)
    index <- lapply(z, function(x) rep(seq_along(x), sapply(x, ncol)))
    wSigma <- lapply(seq_along(z[[1]]), function(j)
                     add(lapply(seq_along(z), function(i) wSum[i]*sum(diag(random$Sigma[[i]])[index[[i]] == j]))))
    bb <- lapply(seq_along(z[[1]]), function(j)
                 add(lapply(seq_along(which), function(i) crossprod(random$beta[[i]][index[[i]] == j])*w[i])))
    psi <- lapply(seq_along(wSigma), function(j) (wSigma[[j]] + bb[[j]])/sum(w * sapply(index, function(x) sum(x == j))))
    list(coefficients = coef(fit),
         sigma2 = list(Random = psi,
           Residual = sigma2),
         df = ncol(x[[1]]))
  }

  object@defineComponent <- expression({
    predict <- function(x, ...) 
      lapply(x, function(X) X %*% coef)
    
    logLik <- function(x, y, z, which, group, ...) {
      V <- lapply(z, function(Z)
                  add(lapply(seq_along(Z), function(j)
                             as.numeric(sigma2$Random[[j]]) * tcrossprod(Z[[j]]))) + diag(nrow(Z[[1]])) * sigma2$Residual)
      mu <- predict(x, ...)
      llh <- sapply(seq_along(x), function(i) 
                    mvtnorm::dmvnorm(t(y[[i]]), mean = mu[[i]], sigma = V[[which[i]]], log=TRUE)/nrow(V[[which[i]]]))
      as.vector(flexmix:::ungroupPriors(matrix(llh), group, !duplicated(group)))
    }
    new("FLXcomponentnestedlmm",
        parameters = list(coef = coef, sigma2 = sigma2),
        random = list(),
        logLik = logLik, predict = predict,
        df = df)
  })

  determineRandom <- function(mu, y, z, which, sigma2) {
    Sigma <- lapply(z, function(Z) {
      solve(crossprod(do.call("cbind", Z)) / sigma2$Residual + diag(1/unlist(lapply(seq_along(Z), function(j) rep(sigma2$Random[[j]], ncol(Z[[j]]))))))
    })
    Sigma_tilde <- lapply(seq_along(z), function(i)
                          (tcrossprod(Sigma[[i]], do.call("cbind", z[[i]])/sigma2$Residual)))
    beta <- lapply(seq_along(Sigma), function(i)
                   Sigma_tilde[[i]] %*% (y[[i]] - mu[[i]]))
    list(beta = beta, Sigma = Sigma)
  }
  
  object@fit <- if (any(varFix)) {
    function(x, y, w, z, which, random) {
      fit <- lapply(seq_len(ncol(w)), function(k) nestedlmm.wfit(x, y, w[,k], z, which, random[[k]]))
      if (varFix["Random"]) {
        prior_w <- apply(w, 2, weighted.mean, w = sapply(x, length))
        Random <- lapply(seq_along(z[[1]]), function(j)
                         add(lapply(seq_along(fit), function(i) fit[[i]]$sigma2$Random[[j]] * prior_w[i])))
        for (i in seq_along(fit)) fit[[i]]$sigma2$Random <- Random
      }
      if (varFix["Residual"]) {
        prior <- colMeans(w)
        Residual <- sum(sapply(fit, function(x) x$sigma2$Residual) * prior)
        for (i in seq_along(fit)) fit[[i]]$sigma2$Residual <- Residual
      }
      n <- sapply(fit[[1]]$sigma2$Random, nrow)
      lapply(fit, function(Z) {
        comp <- with(list(coef = coef(Z),
                          sigma2 =  Z$sigma2,
                          df = Z$df + sum(n*(n+1)/(2*ifelse(varFix["Random"], ncol(w), 1))) + ifelse(varFix["Residual"], 1/ncol(w), 1)),
                     eval(object@defineComponent))
        comp@random <- determineRandom(comp@predict(x), y, z, which, comp@parameters$sigma2)
        comp
      })
    }
  } else {
    function(x, y, w, z, which, random){
      fit <- nestedlmm.wfit(x, y, w, z, which, random)
      n <- sapply(fit$sigma2$Random, nrow)
      comp <- with(list(coef = coef(fit),
                        df = fit$df + sum(n*(n+1)/2) + 1,
                        sigma2 =  fit$sigma2),
                   eval(object@defineComponent))
      comp@random <- determineRandom(comp@predict(x), y, z, which, comp@parameters$sigma2)
      comp
    }
  }
  object
}

setMethod("FLXmstep", signature(model = "FLXMRnestedlmm"),
          function(model, weights, components)
{
  weights <- weights[!duplicated(model@group),,drop=FALSE]
  if (!is(components[[1]], "FLXcomponentnestedlmm")) {
    random <- list(beta = lapply(model@which, function(i) rep(0, sum(unlist(lapply(model@z[[i]], ncol))))),
                   Sigma = lapply(model@z, function(z) diag(sum(unlist(lapply(z, ncol))))))
    return(sapply(seq_len(ncol(weights)),
                  function(k) model@fit(model@x, model@y, weights[,k], model@z, model@which, random)))
 }else {
   return(sapply(seq_len(ncol(weights)),
                 function(k) model@fit(model@x, model@y, weights[,k], model@z, model@which, 
                                       components[[k]]@random)))
 }
})

setMethod("FLXmstep", signature(model = "FLXMRnestedlmmfix"),
          function(model, weights, components)
{
  weights <- weights[!duplicated(model@group),,drop=FALSE]
  if (!is(components[[1]], "FLXcomponentnestedlmm")) {
    random <- rep(list(list(beta = lapply(model@which, function(i) rep(0, sum(unlist(lapply(model@z[[i]], ncol))))),
                            Sigma = lapply(model@z, function(z) diag(sum(unlist(lapply(z, ncol))))))),
                       ncol(weights))
    return(model@fit(model@x, model@y, weights, model@z, model@which, random))
  }else
   return(model@fit(model@x, model@y, weights, model@z, model@which, lapply(components, function(x) x@random)))
})


setMethod("FLXgetModelmatrix", signature(model="FLXMRnestedlmm"),
          function(model, data, formula, lhs=TRUE, ...)
{
  formula_nogrouping <- flexmix:::RemoveGrouping(formula)
  if (identical(paste(deparse(formula_nogrouping), collapse = ""), paste(deparse(formula), collapse = ""))) stop("please specify a grouping variable")
  model <- callNextMethod(model, data, formula, lhs)
  model@fullformula <- update(model@fullformula,
                              paste(".~. |", flexmix:::.FLXgetGroupingVar(formula)))
  lmt1 <- lapply(model@random, function(random) terms(random, data=data))
  lmf <- lapply(lmt1, function(mt1) model.frame(delete.response(mt1), data=data, na.action = NULL))
  lz <- lapply(lmf, function(mf) model.matrix(attr(mf, "terms"), data))
  model@group <- grouping <- flexmix:::.FLXgetGrouping(formula, data)$group
  model@x <- matrix(lapply(unique(grouping), function(g) model@x[grouping == g, , drop = FALSE]), ncol = 1)
  if (lhs) model@y <- matrix(lapply(unique(grouping), function(g) model@y[grouping == g, , drop = FALSE]), ncol = 1)
  lz <- lapply(unique(grouping), function(g) lapply(lz, function(z) {
    z <- z[grouping == g, , drop = FALSE]
    z <- z[,colSums(z) > 0, drop = FALSE]
    z
  }))
  model@which <- seq_along(lz)
  model@z <- matrix(lz, ncol = 1)
  model
})

setMethod("FLXgetObs", "FLXMRnestedlmm", function(model) sum(sapply(model@x, nrow)))

setMethod("FLXdeterminePostunscaled", signature(model = "FLXMRnestedlmm"), function(model, components, ...) {
  sapply(components, function(x) x@logLik(model@x, model@y, model@z, model@which, model@group))
})


