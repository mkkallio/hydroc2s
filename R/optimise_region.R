#' Computes and regionalizes optimal estimate from multiple discharge 
#' timeseries against observed streamflow
#' 
#' Algorithm routes runoff using user specified routing algorithm, for
#' each observation point in sequence starting from the most upstream
#' point. The optimum weight combination is regionalized to the river segments 
#' upstream from the optimisation point which do not contain observation 
#' information. 
#' 
#' See \code{\link{optimise_point}} for help with optimisation options. Note:
#' unlike \code{optimise_point}, runoff does not need to be routed in advance,
#' but it is done by the function automatically.
#' 
#' Currently only one regionalization type is implemented: \code{
#' upstream} uses the weights obtained for the nearest downstream
#' station for the river segment.
#' 
#' Options for \code{no_station} is currently only one: \code{"em"}, 
#' which stands for "ensemble mean". For those river segments with no
#' weights assigned from a station (segments with no downstream observation 
#' station), an ensemble mean (each discharge prediction is given equal weight) 
#' is computed.
#' 
#' @param HS An \code{HS} object with observation_ts and runoff_ts
#' @param routing Routing algorithm to use. See 
#'   \code{\link{accumulate_runoff}} for options.
#' @param region_type How to regionalize combination weights. See details.
#' @param no_station How to handle river segments with no downstream 
#'   stations. See details.
#' @param drop Drop existing timeseries (columns) in \code{runoff_ts}, 
#'   \code{discharge_ts}, or not.
#' @param ... Additional parameters passed to the \code{routing} algorithm 
#'   and/or to optimisation..
#' @inheritParams optimise_point
#' @inheritParams compute_HSweights
#' 
#' @return Returns an \code{HS} object with routed and optimised 
#' \code{discharge_ts}, and additional optimisation information in 
#' \code{Optimisation_info} and \code{Optimised_at}.
#'   
#' @export
optimise_region <- function(HS, 
                            routing = "instant", 
                            train = 0.5,
                            optim_method = "CLS",
                            combination = "ts",
                            sampling = "random",
                            region_type= "upstream", 
                            no_station = "em", 
                            drop = TRUE,
                            ...,
                            verbose = FALSE) {
    
    . <- NULL
    upseg <- NULL
    control_type <- NULL
    control_ts <- NULL
    discharge_ts <- NULL
    warned_overfit <- FALSE
    warned_train <- FALSE
    bias_correction <- FALSE # disabled currently, likely to be removed
    log <- FALSE  # disabled currently, likely to be removed 
    
    # --------------------------------------------------------------------------
    # Check inputs

    test <- is.function(optim_method)
    if(!test) {
        if(optim_method %in% c("EIG2", "GRC", "OLS")) {
            warning(paste0(optim_method, " contains an intercept which may cause ",
                           "considerable amount of negative streamflow estimates in",
                           " river segments with no observations!"))
        }
    }
    
    
    # --------------------------------------------------------------------------
    # preprocess

    if(verbose) message("Initializing..")
    
    statrIDs <- lapply(HS$observation_ts, is.null)
    statrIDs <- which(!unlist(statrIDs))
    stat_names <- HS$observation_station[ statrIDs ]
    if(combination %in% c("monthly", "mon")) mon <- TRUE else mon <- FALSE
    
    # find nearest up- and downstream station for each station
    rind <- statrIDs 
    rind <- data.frame(riverID = HS$riverID[statrIDs], 
                       rind=statrIDs, 
                       upseg = HS$UP_SEGMENTS[statrIDs],
                       station = stat_names) %>%
        dplyr::arrange(upseg)
    
    
    upstations <- data.frame(station = rind$station, up = NA, down = NA)
    
    for (i in seq_along(rind$station)) {
        ds <- downstream(HS, rind$riverID[i])$riverID
        
        temp <- which(HS$riverID[rind$rind] %in% ds)
        upstations$down[i] <- rind$station[temp[2]]
        upstations$up[temp[2]] <- rind$station[i]
    }
    upstations <- suppressMessages(dplyr::left_join(upstations, rind))
    optimizedIDs <- data.frame(riverID = NA, 
                               OPTIMIZED_STATION = NA, 
                               OPTIMIZED_riverID = NA)
    
    if (verbose) {
        message("Optimising river flow..")
        pb <- txtProgressBar(min = 0, max = nrow(upstations)+1, style = 3)
    }
    
    HS <- dplyr::mutate(HS, 
                      Optimisation_info = vector("list", nrow(HS)),
                      Optimised_at = rep(NA, nrow(HS)),
                      discharge_ts = vector("list", nrow(HS))) #%>%
        # dplyr::arrange(riverID)
    
    # record original control timeseries
    controltype <- NULL 
    if(hasName(HS, "control_type")) controltype <- HS$control_type
    controlts <- NULL
    if(hasName(HS, "control_ts")) controlts <- HS$control_ts
    
    
    # --------------------------------------------------------------------------
    # route and combine stations one by one

    
    for(station in 1:nrow(upstations)) {
        
        # choose only upstream
        statup <- upstream(HS, upstations$riverID[station]) %>% 
            tibble::add_column(.type = TRUE)
        statdown <- downstream(HS, upstations$riverID[station]) %>% 
            tibble::add_column(.type = FALSE)
        
        ## check if the station has a downstream segment or not?
        test <- nrow(statdown)
        if(test == 1) {
            statriver <- statup
        } else if(test > 1) {
            # downstream river segments should not have any runoff to avoid
            # counting it many times
            statdown$runoff_ts <- lapply(statdown$runoff_ts, function(x) {
                x[,-1] <- units::set_units(0, "m3/s")
                return(x)
            })
            
            statriver <- rbind(statup, statdown[-1,])
        } else {
            stop("Error in station positions / routing")
        }
        
        # remove those river segments which have already been optimized
        statriver <- statriver[!statriver$riverID %in% optimizedIDs$riverID,]
        statriver$discharge_ts <- NULL
        
        # route
        statriver <- accumulate_runoff(statriver, 
                                       routing_method = routing)#,
                                       # ...)
        
        stationrow <- which(statriver$riverID == upstations$riverID[station])
        flow <- dplyr::left_join(statriver$discharge_ts[[ stationrow ]],
                                 statriver$observation_ts[[ stationrow ]],
                                 by="Date")
        
        flow <- flow[!is.na(flow$observations),]
        
        # if the station has discharge controls, deduct those from obs and 
        # all the predictions. This is needed in order to optimise _only_ runoff
        # from the station specific flow area, and not reoptimise upstream
        # stations. Reoptimising upper stations would lead to deviations in 
        # water balance
        test <- hasName(statriver, "control_ts")
        if(test) {
            test <- is.null(statriver$control_type[[stationrow]])
            if(!test) {
                test <- statriver$control_type[[stationrow]][2] == "discharge"
                if(test) {
                    region_control <- TRUE
                    # deduct control_ts from flow
                    cts <- statriver$control_ts[[stationrow]]
                    dateind <- cts$Date %in% flow$Date
                    for(i in 2:ncol(flow)) {
                        flow[,i] <- flow[,i] - cts[dateind,2]
                    }   
                }
            } else {
                region_control <- FALSE
            }
        } else {
            region_control <- FALSE
        }
        
        colremove <- apply(flow, 2, FUN=function(x) all(is.na(x)))
        if(any(colremove)) {
            flow <- flow[,names(colremove)[!colremove]]
        }
        
        # ----------------------------------------------------------------------
        # Forecast combination entire timeseries or monthly or annual
        if(combination %in% c("timeseries", "ts")) {
            
            comb <- combine_timeseries(flow, 
                                       optim_method, 
                                       sampling,
                                       train,
                                       bias_correction,
                                       log,
                                       warned_overfit,
                                       warned_train)#,
                                       # ...)
            warned_overfit <- comb$warned_overfit
            warned_train <- comb$warned_train
            
        } else if(combination %in% c("monthly", "mon")) {
            
            comb <- combine_monthly(flow, 
                                    optim_method, 
                                    sampling,
                                    train,
                                    bias_correction,
                                    log,
                                    warned_overfit,
                                    warned_train,
                                    ...)
            warned_overfit <- comb$warned_overfit
            warned_train <- comb$warned_train
            
        } else if (combination %in% c("annual", "ann")) {
            comb <- combine_annual(flow, 
                                   optim_method, 
                                   sampling,
                                   train,
                                   bias_correction,
                                   log,
                                   warned_overfit,
                                   warned_train,
                                   ...)
            warned_overfit <- comb$warned_overfit
            warned_train <- comb$warned_train
        }
        
        ##################################################
        # process output - combine timeseries using the obtained weights
        ##################################################
        
        # get the optimized weights and combine
        if(combination %in% c("mon", "monthly")) {
            weights <- as.matrix(comb$Weights[,-1])
        }  else weights <- comb$Weights
        intercept <- comb$Intercept
        bias <- comb$Bias_correction
        
        # if regionalization controls have been applied, combine runoff with 
        # the optimized weights, and route to get discharge. If there were no
        # regionalization controls (the station is an upstream one), just
        # combine.
        # if(region_control) {
            statriver <- combine_runoff(dplyr::select(statriver, -discharge_ts), 
                                        list(Optimized = weights),
                                        intercept = intercept,
                                        bias = rep(0,12),
                                        drop = drop,
                                        monthly = mon)
            statriver <- accumulate_runoff(statriver, 
                                           routing_method = routing)#,
                                           # ...)
        # } else {
        #     statriver <- combine_runoff(statriver, 
        #                                 list(Optimized = weights),
        #                                 intercept = intercept,
        #                                 bias = rep(0,12),
        #                                 drop = drop,
        #                                 monthly = mon)
        # }
        
        # update HS 
        statriver$Optimisation_info[[stationrow]] <- comb
        statriver$Optimised_at <-
            upstations$riverID[station]
        
        updateind <- statriver$.type
        update <- match(statriver$riverID[updateind], HS$riverID)
        HS$discharge_ts[update] <- statriver$discharge_ts[updateind]
        HS$runoff_ts[update] <- statriver$runoff_ts[updateind]
        HS$Optimised_at[update] <- statriver$Optimised_at[updateind]
        HS$Optimisation_info[update] <- statriver$Optimisation_info[updateind]
        
        # mark which river segments have already been optimized
        optimizedIDs <- rbind(optimizedIDs, 
                          data.frame(riverID = statriver$riverID[updateind], 
                             OPTIMIZED_STATION = upstations$station[station],
                             OPTIMIZED_riverID = upstations$riverID[station]))
        
        # create a boundary conditions
        test <- sum(!updateind) > 0
        if(test) {
                boundary <- spread_listc(statriver$discharge_ts[
                    !updateind])[["Optimized"]]
                HS <- add_control(HS, boundary, "m3/s", 
                                  statriver$riverID[!updateind],
                                  "add", "discharge")
        }
        
        if (verbose) setTxtProgressBar(pb, station)
    }
    
    
    ##################################################################
    # after all stations are optimized, process the remaining segments
    ##################################################################
    
    if(no_station == "em") {
        
        # choose only segments which are left
        statriver <- HS[!HS$riverID %in% optimizedIDs$riverID,]
        
        if(nrow(statriver) != 0) {
            
            # mean combination first so that we dont need to route everything
            # and then take mean. instead, route the mean directly
            statriver <- dplyr::select(statriver, -discharge_ts)
            nmods <- ncol(statriver$runoff_ts[[1]])-1
            weights <- rep(1/nmods, nmods)
            
            statriver <- combine_runoff(statriver, 
                                        list(Ensemble_mean = weights),
                                        intercept = intercept,
                                        bias = rep(0,12),
                                        drop = drop,
                                        monthly = mon)
            
            # statriver <- ensemble_summary(statriver, 
            #                               summarise_over_timeseries = FALSE,
            #                               aggregate_monthly = FALSE,
            #                               funs = "mean",
            #                               drop=drop)
            # route
            statriver <- accumulate_runoff(statriver, 
                                           routing_method = routing,
                                           ...)
            
            # update HS 
            for(i in seq_along(statriver$Optimisation_info)) {
                statriver$Optimisation_info[[i]] <- 
                    "Ensemble Mean - not optimized"
            }
            statriver$Optimised_at <- NA
            
            update <- HS$riverID %in% statriver$riverID
            HS$discharge_ts[update] <- statriver$discharge_ts
            HS$runoff_ts[update] <- statriver$runoff_ts
            HS$Optimised_at[update] <- statriver$Optimised_at
            HS$Optimisation_info[update] <- statriver$Optimisation_info
            
            # mark which river segments have already been optimized
            optimizedIDs <- rbind(optimizedIDs, 
                                  data.frame(riverID = statriver$riverID, 
                                             OPTIMIZED_STATION = "Ensemble Mean",
                                             OPTIMIZED_riverID = NA))
        }
    }
    
    if (verbose) setTxtProgressBar(pb, station+1)
    if (verbose) close(pb) 
    
    
    #####################################################
    # Output
    #####################################################
    
    # return original control timeseries, if HS had any. Otherwise remove
    if(is.null(controltype)) {
        HS <- dplyr::select(HS, -control_type)
    } else {
        HS$control_type <- controltype 
    }
    if(is.null(controlts)) {
        HS <- dplyr::select(HS, -control_ts)
    } else {
        HS$control_ts <- controlts
    }
    
    # give names to runoff and discharge cols
    names(HS$runoff_ts) <- HS$riverID
    names(HS$discharge_ts) <- HS$riverID
    
    # return
    HS <- reorder_cols(HS)
    HS <- assign_class(HS, "HS")
    return(HS)
    
} 









