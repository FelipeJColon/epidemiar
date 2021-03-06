% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/cleaners_helpers.R
\name{create_named_list}
\alias{create_named_list}
\title{#' Interpolates missing environmental data.
#' Deprecated, no longer used as extend_env_data() will fill any gaps.
#'
#' @param quo_obsfield Quosure of the user given field that holds the
#'   environmental variable identifiers/names/IDs.
#' @param quo_valuefield Quosure of the user given field that holds the
#'   environmental variable observation value.
#' @param quo_groupfield Quosure of the user given geographic grouping field to
#'   run_epidemia().
#'
#'@inheritParams run_epidemia
#'
#' @return Same data as env_data, with new interpolated field, val_epidemiar, of
#'   the environmental variable data.
#'
env_NA_interpolate <- function(env_data, quo_obsfield, quo_valuefield, quo_groupfield){
  env_data %>%
    #first, mark which ones are observed versus (will be) interpolated
    dplyr::mutate(data_source = ifelse(!is.na(!!quo_valuefield), "Observed", "Interpolated")) %>%
    #two levels of group_by
    dplyr::group_by(!!quo_groupfield, !!quo_obsfield) %>%
    #confirm date sorting
    dplyr::arrange(!!quo_groupfield, !!quo_obsfield, .data$obs_date) %>%
    #interpolate
    #dplyr::mutate(val_epidemiar = !!quo_valuefield,
    #              val_epidemiar = epidemiar::na_approx(.data$val_epidemiar)) %>%
    dplyr::mutate(val_epidemiar = zoo::na.approx(!!quo_valuefield, rule = 2:1, na.rm = FALSE)) %>%
    #finish by ungrouping
    dplyr::ungroup()
}
Create a named list.}
\usage{
create_named_list(...)
}
\arguments{
\item{...}{List of objects, named or not, to be included in the fully named
list.}
}
\description{
Creates a named list from the user given items. Will preserve the names of
items that already have names.
}
\examples{
a <- list("a", "aa", "aaa")
b <- data.frame(x = 1:4, y = 5:8)
create_named_list(a, b, c = rep(1:4))

}
