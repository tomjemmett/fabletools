% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/frequency.R
\name{common_periods}
\alias{common_periods}
\alias{common_periods.default}
\alias{common_periods.tbl_ts}
\alias{common_periods.interval}
\alias{get_frequencies}
\alias{get_frequencies.numeric}
\alias{get_frequencies.NULL}
\alias{get_frequencies.character}
\alias{get_frequencies.Period}
\title{Extract frequencies for common seasonal periods}
\usage{
common_periods(x)

\method{common_periods}{default}(x)

\method{common_periods}{tbl_ts}(x)

\method{common_periods}{interval}(x)

get_frequencies(period, ...)

\method{get_frequencies}{numeric}(period, ...)

\method{get_frequencies}{`NULL`}(period, data, ..., .auto = c("smallest", "largest", "all"))

\method{get_frequencies}{character}(period, data, ...)

\method{get_frequencies}{Period}(period, data, ...)
}
\arguments{
\item{x}{An object containing temporal data (such as a \code{tsibble}, \code{interval}, \code{datetime} and others.)}

\item{period}{Specification of the time-series period}

\item{...}{Other arguments to be passed on to methods}

\item{data}{A tsibble}

\item{.auto}{The method used to automatically select the appropriate seasonal
periods}
}
\value{
A named vector of frequencies appropriate for the provided data.
}
\description{
Extract frequencies for common seasonal periods
}
\examples{
common_periods(tsibble::pedestrian)

}
\references{
\url{https://robjhyndman.com/hyndsight/seasonal-periods/}
}
