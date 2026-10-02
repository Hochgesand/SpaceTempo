#include "timing.h"

#include <math.h>

int st_coefficients(double duration_factor, double reference_hz,
                    double *retention, double *gain)
{
    const double stock_retention = 0.695;
    const double stock_gain = 2.0;
    if (!retention || !gain || retention == gain ||
        !isfinite(duration_factor) || duration_factor < 0.25 ||
        duration_factor > 1.0 || !isfinite(reference_hz) ||
        reference_hz < 30.0 || reference_hz > 1000.0) {
        return -1;
    }
    if (duration_factor == 1.0) {
        *retention = stock_retention;
        *gain = stock_gain;
        return 0;
    }

    /* For error e and velocity v, one step is:
     * v' = a*v + g*e, e' = e - v'/hz.
     * The state matrix has determinant a and trace 1+a-g/hz.
     */
    const double exponent = 1.0 / duration_factor;
    const double trace = 1.0 + stock_retention - stock_gain / reference_hz;
    const double discriminant = trace * trace - 4.0 * stock_retention;
    const double new_retention = pow(stock_retention, exponent);
    double new_trace;
    if (discriminant >= 0.0) {
        const double large_root = 0.5 * (trace + sqrt(discriminant));
        /* Product-based second root avoids subtractive cancellation. */
        const double small_root = stock_retention / large_root;
        new_trace = pow(large_root, exponent) + pow(small_root, exponent);
    } else {
        /* Conjugate roots rho*exp(+/-i theta) remain conjugate after scaling. */
        const double radius = sqrt(stock_retention);
        double cosine = trace / (2.0 * radius);
        cosine = fmax(-1.0, fmin(1.0, cosine));
        new_trace = 2.0 * pow(radius, exponent) * cos(exponent * acos(cosine));
    }
    const double new_gain = reference_hz * (1.0 + new_retention - new_trace);
    if (!isfinite(new_retention) || !isfinite(new_gain) || new_gain <= 0.0) {
        return -1;
    }
    *retention = new_retention;
    *gain = new_gain;
    return 0;
}
