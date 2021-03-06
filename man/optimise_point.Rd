% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/optimise_point.R
\name{optimise_point}
\alias{optimise_point}
\title{Computes optimal estimate at a specific river segment(s)}
\usage{
optimise_point(
  HS,
  optim_method = "CLS",
  combination = "ts",
  sampling = "random",
  train = 0.5,
  ...
)
}
\arguments{
\item{HS}{An \code{HS} object with observation_ts and discharge_ts}

\item{optim_method}{A character object giving the optimisation method to be 
used, or a function to be passed to  \code{\link[stats]{optim}}. 
See details.}

\item{combination}{Whether to do the forecast combination for the entire
timeseries, or each month of the year individually, or for full calendar 
years. Accepts \code{"timeseries"}, \code{"ts"}, or \code{"monthly"}, 
\code{"mon"}, or \code{"annual"}, \code{"ann"}.}

\item{sampling}{How to sample training and testing periods. \code{"series"}
for training serially from beginning, or \code{"random"} for a random
sample for both training and testing periods.}

\item{train}{The share of timeseries used for training period.}

\item{...}{parameters passed to \code{\link[stats]{optim}}, if optim_method
input is a function.}
}
\value{
Returns an object of class \code{HSoptim}, which is a list of
results for each observation station. Each list ielement contains
  \itemize{
    \item riverID
    \item Method: Model averaging method used.
    \item Weights: Vector of optimised model averaging weights. 
    \item Intercept: Intercept from the combination. \code{NA}, if not
      applicable to the method.
    \item Optimised_ts: A \code{tibble} consisting of date, observation and
      optimised timeseries.
    \item Goodness_of_fit. Goodness of fit of the forecast combination
      obtained using \code{\link[hydroGOF]{gof}}.
}
}
\description{
Function performs data assimilation by combining timeseries of downscaled 
discharge estimates against observed streamflow timeseries at all river 
segments with observations.
}
\details{
Optimisation can be performed either using ordinary least squares (OLS), 
Constrained Least Squares (CLS; coefficients positive, add to unity), 
Non-negative Least Squares (NNLS; coefficients positive), Least Squares 
without intercept (GRA), Least squares with no intercept, and coefficients
sum to unity (GRB), Bates-Granger (BG), Standard Eigenvector (EIG1), 
Bias-corrected Eigenvector (EIG2) or selecting the best performing ensemble 
member (best). 

Alternatively, R's \code{\link[stats]{optim}} can be used. In 
that case, \code{optim_method} should be a function which \code{optim} should
attempt to optimise. The function should accept three inputs: \code{par}, 
\code{obs} and \code{pred}. \code{par} is the vector of coefficients 
\code{optim} optimises, obs is the observation timeseries, and pred is a
matrix of inputs to be optimised. Additional arguments passed to \code{optim}
can also be defined.
}
