# Main run_epidemiar() subfunctions related to forecasting

#' Runs the forecast modeling
#'
#'@param epi_data Epidemiological data with case numbers per week, with date
#'  field "obs_date".
#'@param env_data Daily environmental data for the same groupfields and date
#'  range as the epidemiological data. It may contain extra data (other
#'  districts or date ranges). The data must be in long format (one row for each
#'  date and environmental variable combination), and must start at absolutel
#'  minimum \code{laglen} (in \code{fc_control}) days before epi_data for
#'  forecasting.
#'@param env_ref_data Historical averages by week of year for environmental
#'  variables. Used in extended environmental data into the future for long
#'  forecast time, to calculate anomalies in early detection period, and to
#'  display on timeseries in reports.
#'@param env_info Lookup table for environmental data - reference creation
#'  method (e.g. sum or mean), report labels, etc.
#'
#'@param quo_popfield Quosure of user-given field containing population values.
#'@param quo_groupfield Quosure of the user given geographic grouping field to
#'  run_epidemia().
#'@param quo_obsfield Quosure of user given field name of the environmental data
#'  variables
#'@param quo_valuefield Quosure of user given field name of the value of the
#'  environmental data variable observations.
#'
#'@param fc_model_family model choice stand in <<>>
#'@param fc_clusters clusters <<>>
#'@param report_settings all the settings <<>>
#'
#'@param env_variables List of environmental variables <<>>
#'
#'@param groupings A unique list of the geographic groupings (from groupfield).
#'@param report_dates Internally generated set of report date information: min,
#'  max, list of dates for full report, known epidemiological data period,
#'  forecast period, and early detection period.
#'@param valid_run Internal binary for whether this is part of a validation run.
#'
#'
#'@return Named list containing:
#'fc_epi: Full forecasted resulting dataset.
#'fc_res: The forecasted series in report format.
#'env_data_extd: Data set of the environmental data variables extended into the
#'  unknown/future.
#'env_variables_used: list of environmental variables that were used in the
#'  modeling (had to be both listed in model variables input file and present the
#'  env_data dataset)
#'env_dt_ranges: Date ranges of the input environmental data.
#'reg_obj: The regression object from modeling.
#'Unless model_run is TRUE, in which case only the regression object is returned.
#'
#'
run_forecast <- function(epi_data,
                          quo_popfield,
                          quo_groupfield,
                          env_data,
                          quo_obsfield,
                          quo_valuefield,
                          env_ref_data,
                          env_info,
                          fc_model_family,
                          fc_clusters,
                          report_settings,
                          #internal/calculated
                          valid_run,
                          groupings,
                          env_variables,
                          report_dates){

  message("Preparing for forecasting...")


  # trim to the needed env variables as dictated by the model
  env_data <- pull_model_envvars(env_data = env_data,
                                 quo_obsfield = quo_obsfield,
                                 env_var = report_settings[["env_var"]])
  #create alphabetical list of ONLY USED unique environmental variables
  env_variables_used <- dplyr::pull(env_data, !!quo_obsfield) %>% unique() %>% sort()

  # extract start & end dates for each variable for log file
  env_dt_ranges <- dplyr::group_by(env_data, !!quo_obsfield) %>%
    dplyr::summarize(start_dt = min(.data$obs_date), end_dt = max(.data$obs_date))

  # extend data into future, for future forecast portion
  env_data_extd <- extend_env_future(env_data,
                                     quo_groupfield,
                                     quo_obsfield,
                                     quo_valuefield,
                                     env_ref_data,
                                     env_info,
                                     fc_model_family,
                                     #pull from report_settings
                                     epi_date_type = report_settings[["epi_date_type"]],
                                     #calculated/internal
                                     valid_run,
                                     groupings,
                                     env_variables_used,
                                     report_dates)

  epi_data_extd <- extend_epi_future(epi_data,
                                     quo_popfield,
                                     quo_groupfield,
                                     #calculated/internal
                                     groupings,
                                     report_dates)

  # format the data for forecasting algorithm
  env_fc <- env_format_fc(env_data_extd,
                          quo_groupfield,
                          quo_obsfield)
  epi_fc <- epi_format_fc(epi_data_extd,
                          quo_groupfield,
                          fc_clusters)

  # anomalizing the environ data, if requested.


  if (report_settings[["env_anomalies"]]){
    message("Anomalizing the environmental variables...")
    env_fc <- anomalize_env(env_fc,
                            quo_groupfield,
                            nthreads = report_settings[["fc_nthreads"]],
                            #calculated/internal
                            env_variables_used)
  }

  # create the lags
  epi_lag <- lag_environ_to_epi(epi_fc,
                                env_fc,
                                quo_groupfield,
                                lag_len = report_settings[["env_lag_length"]],
                                #calculated/internal
                                groupings,
                                env_variables_used)

  # add week of year, needed for null-weekaverage model
  # switch epi_date_type to week_type needed for add_datefields()
  week_type <- dplyr::case_when(
    report_settings[["epi_date_type"]] == "weekISO" ~ "ISO",
    report_settings[["epi_date_type"]] == "weekCDC"  ~ "CDC",
    #default as if mean
    TRUE             ~ NA_character_)
  epi_lag <- add_datefields(epi_lag, week_type)


  #<<>> FIX
  # # If only model_run, then return to run_epidemia() here
  # if (model_run){
  # model_run_result <- forecast_regression(epi_lag,
  #                                         quo_groupfield,
  #                                         fc_model_family,
  #                                         nthreads = report_settings[["fc_nthreads"]],
  #                                         model_run,
  #                                         model_cached = report_settings[["model_cached"]],
  #                                         fit_freq = report_settings[["fc_fit_freq"]],
  #                                         #internal calculated
  #                                         groupings,
  #                                         env_variables_used,
  #                                         report_dates,
  #                                         req_date = report_dates$full$max)
  #
  #   model_run_only <- create_named_list(env_variables_used,
  #                                       env_dt_ranges,
  #                                       reg_obj = model_run_result)
  #   return(model_run_only)
  # }


  #Split regression call depending on {once|week} model fit frequency

  if (report_settings[["fc_fit_freq"]] == "once"){
    message("Generating forecasts...")
    #for single fit, call with last week (and subfunction has switch to return all)
    forereg_return <- forecast_regression(epi_lag,
                                          quo_groupfield,
                                          fc_model_family,
                                          nthreads = report_settings[["fc_nthreads"]],
                                          model_run = report_settings[["model_run"]],
                                          model_cached = report_settings[["model_cached"]],
                                          fit_freq = report_settings[["fc_fit_freq"]],
                                          #internal calculated
                                          groupings,
                                          env_variables_used,
                                          report_dates,
                                          req_date = report_dates$full$max)
    preds_catch <- forereg_return$date_preds
    reg_obj <- forereg_return$regress

  } else if (report_settings[["fc_fit_freq"]] == "week") {
    # for each week of report, run forecast
    # initialize: prediction returns 4 columns
    preds_catch <- data.frame()
    #loop by week
    for (w in seq_along(report_dates$full$seq)){
      message("Forecasting week ", w, " starting at ", Sys.time())
      dt <- report_dates$full$seq[w]
      forereg_return <- forecast_regression(epi_lag,
                                            quo_groupfield,
                                            fc_model_family,
                                            nthreads = report_settings[["fc_nthreads"]],
                                            model_run = report_settings[["model_run"]],
                                            model_cached = report_settings[["model_cached"]],
                                            fit_freq = report_settings[["fc_fit_freq"]],
                                            #internal calculated
                                            groupings,
                                            env_variables_used,
                                            report_dates,
                                            req_date = dt)

      dt_preds <- forereg_return$date_preds
      preds_catch <- rbind(preds_catch, as.data.frame(dt_preds))

      #taking advantage that only result will be of the last loop through
      reg_obj <- forereg_return$regress
    }

  } else stop("Model fit frequency unknown") #shouldn't happen with default "once"


  # Interval calculation
  preds_catch <- preds_catch %>%
    dplyr::mutate(fc_cases = .data$fit,
                  fc_cases_upr = .data$fit+1.96*sqrt(.data$fit),
                  fc_cases_lwr = .data$fit-1.96*sqrt(.data$fit))

  # extract fc series into report format
  fc_res <- preds_catch %>%
    dplyr::mutate(series = "fc",
                  value = dplyr::case_when(
                    #if reporting in case counts
                    report_settings[["report_value_type"]] == "cases" ~ fc_cases,
                    #if incidence
                    report_settings[["report_value_type"]] == "incidence" ~ fc_cases / !!quo_popfield * report_settings[["report_inc_per"]],
                    #otherwise
                    TRUE ~ NA_real_),
                  lab = "Forecast Trend",
                  upper = dplyr::case_when(
                    #if reporting in case counts
                    report_settings[["report_value_type"]] == "cases" ~ fc_cases_upr,
                    #if incidence
                    report_settings[["report_value_type"]] == "incidence" ~ fc_cases_upr / !!quo_popfield * report_settings[["report_inc_per"]],
                    #otherwise
                    TRUE ~ NA_real_),
                  lower = dplyr::case_when(
                    #if reporting in case counts
                    report_settings[["report_value_type"]] == "cases" ~ fc_cases_lwr,
                    #if incidence
                    report_settings[["report_value_type"]] == "incidence" ~ fc_cases_lwr / !!quo_popfield * report_settings[["report_inc_per"]],
                    #otherwise
                    TRUE ~ NA_real_)
                  #value = fc_cases / !!quo_popfield * inc_per,
                  #upper = fc_cases_upr / !!quo_popfield * inc_per,
                  #lower = fc_cases_lwr / !!quo_popfield * inc_per
    ) %>%
    dplyr::select(!!quo_groupfield, .data$obs_date, .data$series, .data$value, .data$lab, .data$upper, .data$lower)

  # return list with res and other needed items
  fc_res_full <- create_named_list(fc_epi = preds_catch,
                                   fc_res,
                                   env_data_extd,
                                   env_variables_used,
                                   env_dt_ranges,
                                   reg_obj)
}


#' Run forecast regression
#'
#'@param epi_lag Epidemiological dataset with basis spline summaries of the
#'  lagged environmental data (or anomalies), as output by lag_environ_to_epi().
#'@param quo_groupfield Quosure of the user given geographic grouping field to
#'  run_epidemia().
#'@param fc_model_family model choice stand in
#'@param nthreads max threads <<>>
#'@param model_run TRUE/FALSE flag for whether to only generate the model
#'  regression object plus metadata. This model can be cached and used later on
#'  its own, skipping a large portion of the slow calculations for future runs.
#'@param model_cached The output of a previous model_run = TRUE run of
#'  run_epidemia() that produces a model (regression object) and metadata. The
#'  metadata will be used for input checking and validation. Using a prebuilt
#'  model saves on processing time, but will need to be updated periodically.
#'@param fit_freq String indicating "once" or "weekly" on how often to fit the
#'  model - once for the whole report, or every week of the report. Unless
#'  otherwise needed, the value should be "once", as weekly drastically
#'  increases processing time.
#'@param groupings A unique list of the geographic groupings (from groupfield).
#'@param env_variables_used List of environmental variables that were used in
#'  the modeling.
#'@param report_dates Internally generated set of report date information: min,
#'  max, list of dates for full report, known epidemiological data period,
#'  forecast period, and early detection period.
#'@param req_date The end date of requested forecast regression. When fit_freq
#'  == "once", this is the last date of the full report, the end date of the
#'  forecast period.
#'
#'
#'@return Named list containing:
#'date_preds: Full forecasted resulting dataset.
#'reg_obj: The regression object from modeling.
#'Unless model_run is TRUE, in which case only the regression object is returned.
#'
#'
forecast_regression <- function(epi_lag,
                                quo_groupfield,
                                fc_model_family,
                                nthreads,
                                model_run,
                                model_cached = NULL,
                                fit_freq,
                                #internal calculated
                                groupings,
                                env_variables_used,
                                report_dates,
                                req_date){

  if (fit_freq == "once"){
    #single fits use all the data available
    last_known_date <-  report_dates$known$max
  } else if (fit_freq == "week"){
    # for "week" model fits, forecasts are done knowing up to just before that date
    last_known_date <- req_date - lubridate::as.difftime(1, units = "days")
  }

  ## Set up data

  #mark known or not
  epi_lag <- epi_lag %>%
    dplyr::mutate(known = ifelse(.data$obs_date <= last_known_date, 1, 0))

  # ensure that quo_name(quo_groupfield) is a factor - gam/bam will fail if given a character,
  # which is unusual among regression functions, which typically just coerce into factors.
  epi_lag <- epi_lag %>% dplyr::mutate(!!rlang::quo_name(quo_groupfield) := factor(!!quo_groupfield))
  #number of geographic area groupings
  n_groupings <- epi_lag %>% dplyr::pull(!!quo_groupfield) %>% nlevels()

  #number of clusters
  n_clusters <- nlevels(epi_lag$cluster_id)

  # create a doy field so that we can use a cyclical spline
  epi_lag <- dplyr::mutate(epi_lag, doy = as.numeric(format(.data$obs_date, "%j")))

  # create modified bspline basis in epi_lag file to model longterm trends
  epi_lag <- cbind(epi_lag, truncpoly(x=epi_lag$obs_date,
                                      degree=6,
                                      maxobs=max(epi_lag$obs_date[epi_lag$known==1], na.rm=TRUE)))



  ## If model_cached is NOT given, then create model / run regression
  if (is.null(model_cached)){

    #create variable bandsummaries equation piece
    #  e.g. 'bandsummaries_{var1} * cluster_id' for however many env var bandsummaries there are
    bandsums_list <- grep("bandsum_*", colnames(epi_lag), value = TRUE)
    bandsums_cl_list <- paste(bandsums_list, ": cluster_id")
    #need variant without known multiplication if <= 1 clusters
    if (n_clusters > 1) {
      bandsums_eq <- glue::glue_collapse(bandsums_cl_list, sep =" + ")
    } else {
      bandsums_eq <- glue::glue_collapse(bandsums_list, sep = " + ")
    }

    # get list of modbspline reserved variables and format for inclusion into model
    modb_list <- grep("modbs_reserved_*", colnames(epi_lag), value = TRUE)
    # variant depending on >1 geographic area groupings
    if (n_groupings > 1){
      modb_list_grp <- paste(modb_list, ":", rlang::quo_name(quo_groupfield))
      modb_eq <- glue::glue_collapse(modb_list_grp, sep = " + ")
    } else {
      modb_eq <- glue::glue_collapse(modb_list, sep = " + ")
    }

    #filter to known
    epi_known <- epi_lag %>% dplyr::filter(.data$known == 1)


    # Model building switching point

    regress <- build_model(fc_model_family,
                           quo_groupfield,
                           epi_known,
                           nthreads,
                           #calc/internal
                           n_groupings,
                           modb_eq,
                           bandsums_eq)

  } else {
    #if model_cached given, then use that as regress instead of building a new one (above)

    #message with model input
    message("Using given cached ", model_cached$model_info$fc_model_family, " model, created ",
            model_cached$model_info$date_created, ", with epidemiological data up through ",
            model_cached$model_info$known_epi_range$max, ".")

    regress <- model_cached$model_obj
  }

  ## If model run, return regression object to run_forecast() at this point
  if (model_run){
    return(regress)
  }

  ## Creating predictions switching point on model choice
  preds <- create_predictions(fc_model_family,
                              nthreads,
                              regress,
                              epi_lag,
                              req_date)


  ## Clean up
  #remove distributed lag summaries and bspline basis, which are no longer helpful
  band_names <- grep("bandsum_*", colnames(epi_lag), value = TRUE)
  bspl_names <- grep("modbs_reserved_*", colnames(epi_lag), value = TRUE)
  #remove
  epi_lag_trim <- dplyr::select(epi_lag, -dplyr::one_of(band_names))
  epi_lag_trim <- dplyr::select(epi_lag_trim, -dplyr::one_of(bspl_names))


  #now cbind to get ready to return
  epi_preds <- cbind(epi_lag_trim %>%
                       dplyr::filter(.data$obs_date <= req_date),
                     as.data.frame(preds)) %>%
    #and convert factor back to character for the groupings (originally converted b/c of bam/gam requirements)
    dplyr::mutate(!!rlang::quo_name(quo_groupfield) := as.character(!!quo_groupfield))

  if (fit_freq == "once"){
    #for single model fit, this has all the data we need, just trim to report dates
    date_preds <- epi_preds %>%
      dplyr::filter(.data$obs_date >= report_dates$full$min)
  } else if (fit_freq == "week"){
    #prediction of interest are last ones (equiv to req_date) per groupfield
    date_preds <- epi_preds %>%
      dplyr::group_by(!!quo_groupfield) %>%
      dplyr::filter(.data$obs_date == req_date)
  }

  forecast_reg_results <- create_named_list(date_preds,
                                            regress)
}


#'Build the appropriate model
#'
#'@param fc_model_family model choice stand in <<>>
#'@param quo_groupfield Quosure of the user given geographic grouping field to
#'  run_epidemia().
#'@param epi_known Epidemiological dataset with basis spline summaries of the
#'  lagged environmental data (or anomalies), with column marking if "known"
#'  data and groupings converted to factors.
#'@param nthreads thread count <<>>
#'@param n_groupings Count of the number of geographic groupings in the model.
#'@param modb_eq Pieces of the regression formula that include the modified
#'  basis functions to account for long term trend (with or without groupings,
#'  as appropriate).
#'@param bandsums_eq Pieces of the regression formula that include the b-spline
#'  bandsummaries of the environmental factors.

#'
#'@return Regression object
#'
#'
build_model <- function(fc_model_family,
                        quo_groupfield,
                        epi_known,
                        nthreads,
                        #calc/internal
                        n_groupings,
                        modb_eq,
                        bandsums_eq){

  #POISSON-BAM (set as default in first round input checking)
  if (fc_model_family == "poisson-bam"){

    message("Building Poisson model using bam() and forced cyclical...")

    #due to dplyr NSE and bandsum eq and modb_eq pieces, easier to create
    #expression to give to modeling function
    #different versions if multiple geographic area groupings or not
    if (n_groupings > 1){
      reg_eq <- stats::as.formula(paste("cases_epidemiar ~ ",
                                        rlang::quo_name(quo_groupfield),
                                        " + s(doy, bs=\"cc\", by=",
                                        rlang::quo_name(quo_groupfield),
                                        ") + ",
                                        modb_eq, " + ",
                                        bandsums_eq))
    } else {
      reg_eq <- stats::as.formula(paste("cases_epidemiar ~ ",
                                        "s(doy, bs=\"cc\") + ",
                                        modb_eq, " + ",
                                        bandsums_eq))
    }

    # run bam
    # Using discrete = TRUE was much faster than using parallel with bam.
    regress <- mgcv::bam(reg_eq, data = epi_known,
                         family = stats::poisson(),
                         control = mgcv::gam.control(trace=FALSE),
                         discrete = TRUE,
                         nthreads = nthreads)


  } else if (fc_model_family == "negbin"){
    #NEGATIVE BINOMIAL using GLM

    message("Building negative binomial model...")

    #due to dplyr NSE and bandsum eq and modb_eq pieces, easier to create
    #expression to give to modeling function
    #different versions if multiple geographic area groupings or not
    #No cycical (as opposed to bam with s())
    if (n_groupings > 1){
      reg_eq <- stats::as.formula(paste("cases_epidemiar ~ ",
                                        rlang::quo_name(quo_groupfield), " + ",
                                        modb_eq, " + ",
                                        bandsums_eq))
    } else {
      reg_eq <- stats::as.formula(paste("cases_epidemiar ~ ",
                                        modb_eq, " + ",
                                        bandsums_eq))
    }

    # run glm
    # Which negative binomial function depends on if fc_control$theta exists
    #<<>> temp set theta to null until switch to real model family
    theta <- NULL

    if(!is.null(theta)){
      message("Theta value provided. Running with glm(..., family = MASS::negative.binomial(theta = ", theta, "))...")
      regress <- stats::glm(reg_eq,
                            data = epi_known,
                            #theta value REQUIRED
                            family = MASS::negative.binomial(theta=2.31))
                            #family = MASS::negative.binomial(theta = theta))
    } else {
      message("Theta estimate (fc_control$theta) not provided, running with MASS::glm.nb()...")
      regress <- MASS::glm.nb(reg_eq,
                              data = epi_known)
    }


  } else if (fc_model_family == "naive-persistence"){

    #naive model
    #persistence (carry forward)
    #no regression object

    #create "model" using known data.
    #Will fill down in create_predictions
    regress <- epi_known %>%
      #grouping by geographical unit
      dplyr::group_by(!!quo_groupfield) %>%
      #prediction is 1 lag (previous week)
      #fit is name of value from regression models
      dplyr::mutate(fit = dplyr::lag(.data$cases_epidemiar, n = 1)) %>%
      #cleaning up as not needed, and for bug hunting
      dplyr::select(-dplyr::starts_with("band")) %>%
      dplyr::select(-dplyr::starts_with("modbs"))



  } else if (fc_model_family == "naive-averageweek"){

    #naive model
    #average of week of year (from historical data)
    #not a regression object

    #create "model" (averages) using known data.
    regress <- epi_known %>%
      #calculate averages per geographic group per week of year
      dplyr::group_by(!!quo_groupfield, .data$week_epidemiar) %>%
      dplyr::summarize(fit = mean(.data$cases_epidemiar, na.rm = TRUE))


  } else {
    #Shouldn't happen, just in case.
    stop("Error in selecting model choice.")
  }
} # end build_model()



#'Create the appropriate predictions/forecasts.
#'
#'@param fc_model_family model choice <<>>
#'@param nthreads max threads <<>>
#'@param regress The regression object, either the user-supplied one, or
#'  the one just generated.
#'@param epi_lag Epidemiological dataset with basis spline summaries of the
#'  lagged environmental data (or anomalies), with groupings as a factor.
#'@param req_date The end date of requested forecast regression. When fit_freq
#'  == "once", this is the last date of the full report, the end date of the
#'  forecast period.
#'
#'@return A dataset from predict() using the regression object generated in
#'  build_model or a newly created one. The dataset includes the
#'  predicted/forecast values through the end of the report requested.
#'
#'
create_predictions <- function(fc_model_family,
                               nthreads,
                               regress,
                               epi_lag,
                               req_date){

  #POISSON-BAM (set as default in first round input checking)
  if (fc_model_family == "poisson-bam"){

    message("Creating Poisson predictions...")


    ## Create predictions from either newly generated model, or given one

    #output prediction (through req_date)
    preds <- mgcv::predict.bam(regress,
                               newdata = epi_lag %>% dplyr::filter(.data$obs_date <= req_date),
                               se.fit = TRUE,       # included for backwards compatibility
                               type="response",
                               discrete = TRUE,
                               n.threads = nthreads)



  } else if (fc_model_family == "negbin"){
    #NEGATIVE BINOMIAL using GLM

    message("Creating negative binomial predictions...")


    ## Create predictions from either newly generated model, or given one

    #output prediction (through req_date)
    preds <- stats::predict.glm(regress,
                                newdata = epi_lag %>% dplyr::filter(.data$obs_date <= req_date),
                                se.fit = TRUE,       # included for backwards compatibility
                                type="response")


  } else if (fc_model_family == "naive-persistence"){

    message("Creating predictions using persistence naive model...")

    #persistence model just carries forward the last known value
    #the important part is the forecast / trailing end part
    #manipulating to be in quasi-same format as the other models return

    #cleaning up as not needed, and for bug hunting
    epi_lag <- epi_lag %>%
      dplyr::select(-dplyr::starts_with("band")) %>%
      dplyr::select(-dplyr::starts_with("modbs"))

    #regress is a tibble not regression object here
    # has a variable fit with lag of 1 on known data
    #epi_lag has the newer rows
    preds <- epi_lag %>%
      #filter to requested date
      dplyr::filter(.data$obs_date <= req_date) %>%
      #join to get "fit" values from "model"
      #join on all shared columns (i.e. everything in regress not "fit") to prevent renaming
      dplyr::left_join(regress, by = names(regress)[!names(regress) %in% c("fit")]) %>%
      #important at end/fc section, when we fill down
      tidyr::fill(.data$fit, .direction = "down") %>%
      #format into nominal regression predict output
      dplyr::select(.data$fit) %>%
      as.data.frame()

  } else if (fc_model_family == "naive-averageweek"){

    message("Creating predictions using average week of year naive model...")

    #average week null model calculates the average cases of that
    # week of year from historical data
    #manipulating to be in quasi-same format as the other models return

    #regress is the averages per week of year from known data

    epi_lag <- epi_lag %>%
      #filter to requested date
      dplyr::filter(.data$obs_date <= req_date)

    #join back
    preds <- epi_lag %>%
      #join to get average values
      #join on all shared columns (i.e. everything in regress not "fit") to prevent renaming
      # and so don't need column names not passed into this function
      dplyr::left_join(regress, by = names(regress)[!names(regress) %in% c("fit")]) %>%
      #format into nominal regression output
      dplyr::select(.data$fit) %>%
      as.data.frame()


  } else {
    #Shouldn't happen, just in case.
    stop("Error in selecting model choice.")
  }

} #end create_predictions()