#ifndef SPACETEMPO_TIMING_H
#define SPACETEMPO_TIMING_H

/*
 * Return 0 on success, -1 for invalid arguments. Outputs are unchanged on error.
 * duration_factor is in [0.25, 1]; reference_hz is in [30, 1000].
 *
 * At the reference refresh rate this maps both discrete spring eigenvalues
 * to their 1/duration_factor power. It scales modal decay, not a measured
 * wall-clock duration: initial velocity and Dock's settling thresholds also
 * affect the time to completion. Coefficients calculated at 120 Hz are an
 * approximation when used on a display with a different refresh rate.
 */
int st_coefficients(double duration_factor, double reference_hz,
                    double *retention, double *gain);

#endif
