
## function that gets an n\times p matrix of p genotypes of n individuals, and a null model, and tests the genotypes associations with the outcomes. 
## Genetic data are always assumed complete. 
## Types of tests: 
## Single variant: Score, Score.SPA, BinomiRare, interaction. 
## Variant set: SKAT, burden, SKAT-O. Multiple types of p-values. Default: Davis with Koenen if does not converge. 


# E an environmental variable for optional GxE interaction analysis. 
testGenoSingleVar <- function(nullmod, G, E = NULL, test = c("Score", "Score.SPA"),
                              recalc.pval.thresh = 1, GxE.return.cov = FALSE){
    test <- match.arg(test)

    G <- .genoAsMatrix(nullmod, G)

    # checks on test
    if (!is.null(E)){
        message("Performing GxE test")
        res <- .testGenoSingleVarWaldGxE(nullmod, G, E, GxE.return.cov.mat=GxE.return.cov)
        return(res)
    }
 
    if(test == "Score.SPA" & nullmod$family$family != "binomial"){
        test <- "Score"
        message("Saddlepoint approximation (SPA) can only be used for binomial family; using Score test instead.")
    }

    # run the test
    if(test == "Score"){
        Gtilde <- calcGtilde(nullmod, G)
        if(is.null(nullmod$RSS0)){
            nullmod$RSS0 <- as.numeric(crossprod(nullmod$Ytilde))
        }
        res <- .testGenoSingleVarScore(Gtilde, G, nullmod$resid, nullmod$RSS0)
    }

    if(test == "Score.SPA"){
        Gtilde <- calcGtilde(nullmod, G)
        if(is.null(nullmod$RSS0)){
            nullmod$RSS0 <- as.numeric(crossprod(nullmod$Ytilde))
        }
        res <- .testGenoSingleVarScore(Gtilde, G, nullmod$resid, nullmod$RSS0)
        # saddle point approximation
        res <- SPA_pval(score.result = res, nullmod = nullmod, G = G, pval.thresh = recalc.pval.thresh)
    }
    
    if (test == "BinomiRare"){
        if (nullmod$family$mixedmodel) stop("BinomiRare should be used for IID observations.")
        if (nullmod$family$family != "binomial") stop("BinomiRare should be used for disease (binomial) outcomes.")
    	res <- .testGenoSingleVarBR(nullmod$outcome, probs=nullmod$fitted.values, G)
    }

    return(res)
}


## this function currently assumes that the alt allele is the minor allele. So either G 
## needs to be such that alt allele is minor allele, or the function checks for it, or a vector of 
## indicators or of frequencies would be provided. 
.testGenoSingleVarBR <- function(D, probs, G){
    if (!requireNamespace("poibin")) stop("package 'poibin' must be installed for the BinomiRare test")
    res <- data.frame(n.carrier = NA, n.D.carrier = NA, expected.n.D.carrier = NA, pval = NA)
    
    for (i in 1:ncol(G)){
        carrier.inds <- which(G[,i] > 0)
        res$n.carrier[i] <- length(carrier.inds)
        cur.prob.vec <- probs[carrier.inds]
        res$expected.n.D.carrier[i] <- sum(cur.prob.vec)
        res$n.D.carrier[i] <- sum(D[carrier.inds])
        
        res$pval[i] <- .poibinMidp(n.carrier = res$n.carrier[i], n.D.carrier = res$n.D.carrier[i], prob.vec = cur.prob.vec)		 
    }

    return(res)
}


.poibinMidp <- function(n.carrier, n.D.carrier, prob.vec){
    stopifnot(n.D.carrier <= n.carrier, length(prob.vec) == n.carrier)
    d.poibin <- poibin::dpoibin(0:n.carrier, prob.vec)
    prob.cur <- d.poibin[n.D.carrier + 1]
    mid.p <- 0.5*prob.cur + sum(d.poibin[d.poibin < prob.cur])
    return(mid.p)
}



.testGenoSingleVarScore <- function(Gtilde, G, resid, RSS0){
    GPG <- colSums(Gtilde^2) # vector of G^T P G (for each SNP)
    score.SE <- sqrt(GPG)
    score <- as.vector(crossprod(G, resid)) # G^T P Y
    Stat <- score/score.SE
    
    res <- data.frame(Score = score, Score.SE = score.SE, Score.Stat = Stat, 
                      Score.pval = pchisq(Stat^2, df = 1, lower.tail = FALSE),
                      Est = score/GPG, Est.SE = 1/score.SE, 
                      PVE = (Stat^2)/RSS0) # RSS0 = (n-k) when gaussian; not when binary
    
    return(res)
}



# .testGenoSingleVarWald <- function(Gtilde, Ytilde, n, k){
#     GPG <- colSums(Gtilde^2) # vector of G^T P G (for each SNP)
#     GPY <- as.vector(crossprod(Gtilde, Ytilde)) # vector of G^T P Y (for each SNP)
#     beta <- GPY/GPG
#     sY2 <- sum(Ytilde^2)
#     RSS <- as.numeric((sY2 - GPY * beta)/(n - k - 1))
#     Vbeta <- RSS/GPG
#     Stat <- beta/sqrt(Vbeta)
#     res <- data.frame(Est = beta, Est.SE = sqrt(Vbeta), Wald.Stat = Stat, 
#                       Wald.pval = pchisq(Stat^2, df = 1, lower.tail = FALSE))
#     return(res)
# }


.testGenoSingleVarWaldGxE <- function(nullmod, G, E, GxE.return.cov.mat = FALSE){

    E <- as.matrix(E)
    p <- ncol(G)
    v <- ncol(E) + 1
    n <- length(nullmod$Ytilde)
    k <- ncol(nullmod$model.matrix)
    sY2 <- as.numeric(crossprod(nullmod$Ytilde))
    
    if (GxE.return.cov.mat) {
        res.Vbetas <- vector(mode = "list", length = p)
    }
    
    intE <- cbind(1, E) # add intercept the "Environmental" variable E.
    if (is(G, "Matrix")) intE <- Matrix(intE)
    
    var.names <- c("G", paste("G", colnames(E), sep = ":"))
    
    res <- matrix(NA, nrow = p, ncol = length(var.names)*2 + 2,
                  dimnames = list(NULL, 
                                  c(paste0("Est.", var.names), paste0("SE.", var.names), "GxE.Stat", "Joint.Stat" ) ))

    for (g in 1:p) {
        Gtilde <- calcGtilde(nullmod, G[, g] * intE)
        GPG <- crossprod(Gtilde)
        GPGinv <- tryCatch(chol2inv(chol(GPG)), error = function(e) {TRUE}) # this is inverse A matrix of sandwich
        # check that the error function above hasn't been called (which returns TRUE instead of the inverse matrix)
        if (is.logical(GPGinv)) next
        
        GPY <- crossprod(Gtilde, nullmod$Ytilde)
        betas <- crossprod(GPGinv, GPY)
        res[g, grep("^Est\\.G", colnames(res))] <- as.vector(betas)
        
        RSS <- as.numeric((sY2 - crossprod(GPY, betas))/(n - k - v))
        Vbetas <- GPGinv * RSS
        
        if (GxE.return.cov.mat) {
            res.Vbetas[[g]] <- Vbetas
        }
        
        res[g, grep("^SE\\.G", colnames(res))] <- sqrt(diag(Vbetas))
        
        res[g, "GxE.Stat"] <- tryCatch(sqrt(as.vector(crossprod(betas[-1],
                                                 crossprod(chol2inv(chol(Vbetas[-1, -1])),
                                                           betas[-1])))), 
                                       error = function(e) { NA })
        
        res[g, "Joint.Stat"] <- tryCatch(sqrt(as.vector(crossprod(betas,
                                                   crossprod(GPG, betas))/RSS)), 
                                         error = function(e) { NA })
    }
    
    res <- as.data.frame(res)
    res$GxE.pval <- pchisq((res$GxE.Stat)^2, df = (v - 1), lower.tail = FALSE)
    res$Joint.pval <- pchisq((res$Joint.Stat)^2, df = v, lower.tail = FALSE)
    
    if (GxE.return.cov.mat) {
        return(list(res = res, GxEcovMatList = res.Vbetas))
    } else {
        return(res)
    }
}



## G is an n by v matrix of 2 or more columns, all representing alleles of the same (multi-allelic) variant. 
.testSingleVarMultAlleles <- function(Gtilde, Ytilde, n, k){
    v <- ncol(Gtilde)
    
    var.names <- colnames(Gtilde)
    
    res <- matrix(NA, nrow = 1, ncol = length(var.names)*2 + 2,
                  dimnames = list(NULL, 
                                  c(paste0("Est.", var.names), paste0("SE.", var.names), "Joint.Stat", "Joint.Pval" ) ))
    
    
    GPG <- crossprod(Gtilde)
    GPGinv <- tryCatch(chol2inv(chol(GPG)), error = function(e) {TRUE})
    
    if (is.logical(GPGinv)) return(list(res = res, allelesCovMat = NA))
    
    GPY <- crossprod(Gtilde, Ytilde)
    betas <- crossprod(GPGinv, GPY) ## effect estimates of the various alleles
    res[1, grep("^Est\\.G", colnames(res))] <- betas
    
    sY2 <- sum(Ytilde^2)
    RSS <- as.numeric((sY2 - crossprod(GPY, betas))/(n - k - v))
    Vbetas <- GPGinv * RSS
    
    res[1, grep("^SE\\.G", colnames(res))] <- sqrt(diag(Vbetas))
    
    res[1, "Joint.Stat"] <- tryCatch(crossprod(betas,
                                               crossprod(GPG, betas))/RSS, 
                                     error = function(e) { NA })
    
    res[,"Joint.pval"] <- pchisq(res[,"Joint.Stat"], df = v, lower.tail = FALSE)
    
    res <- as.data.frame(res)
    return(list(res = res, allelesCovMat = Vbetas))
}





