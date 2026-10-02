#include "timing.h"

#include <assert.h>
#include <math.h>
#include <stdio.h>

static double settle_time(double a, double g, double hz)
{
    double error = 1.0, velocity = 0.0;
    for (int frame = 1; frame <= 20000; ++frame) {
        velocity = a * velocity + g * error;
        error -= velocity / hz;
        assert(isfinite(error) && isfinite(velocity));
        if (fabs(error) < 0.001 && fabs(velocity) < 0.01) {
            return frame / hz;
        }
    }
    assert(!"Spring did not settle");
    return 0;
}

static void assert_stable(double a, double g, double hz)
{
    /* Jury criterion for z^2 - trace*z + a, without complex arithmetic. */
    const double trace = 1.0 + a - g / hz;
    assert(a > 0.0 && a < 1.0);
    assert(1.0 - trace + a > 0.0);
    assert(1.0 + trace + a > 0.0);
    (void)settle_time(a, g, hz);
}

int main(void)
{
    double a = -7.0, g = -9.0;
    const double invalid_factors[] = {NAN, INFINITY, -1.0, 0.0, 0.249, 1.001};
    for (unsigned i = 0; i < sizeof invalid_factors / sizeof *invalid_factors; ++i) {
        assert(st_coefficients(invalid_factors[i], 120.0, &a, &g) == -1);
        assert(a == -7.0 && g == -9.0);
    }
    const double invalid_rates[] = {NAN, INFINITY, 0.0, 29.0, 1001.0};
    for (unsigned i = 0; i < sizeof invalid_rates / sizeof *invalid_rates; ++i) {
        assert(st_coefficients(0.5, invalid_rates[i], &a, &g) == -1);
        assert(a == -7.0 && g == -9.0);
    }
    assert(st_coefficients(0.5, 120, NULL, &g) == -1);
    assert(st_coefficients(0.5, 120, &a, NULL) == -1);
    assert(st_coefficients(0.5, 120, &a, &a) == -1);
    assert(st_coefficients(1.0, 60, &a, &g) == 0);
    assert(a == 0.695 && g == 2.0);

    /* An integer exponent gives an independent closed-form oracle for both
     * real (120 Hz) and complex (60 Hz) stock eigenvalues. */
    const double rates[] = {60, 90, 120, 144};
    for (unsigned i = 0; i < sizeof rates / sizeof *rates; ++i) {
        const double hz = rates[i];
        const double trace = 1.695 - 2.0 / hz;
        assert(st_coefficients(0.5, hz, &a, &g) == 0);
        assert(fabs(a - 0.695 * 0.695) < 1e-13);
        const double expected_gain = hz * (1.0 + a - (trace * trace - 2.0 * 0.695));
        assert(fabs(g - expected_gain) < 1e-10);
    }

    /* Exercise every refresh rate, complex roots, and fractional exponents.
     * Verify both local coefficients and the product's 120 Hz reference. */
    for (int hz = 60; hz <= 144; ++hz) {
        for (int quarter_percent = 25; quarter_percent <= 100; ++quarter_percent) {
            const double factor = quarter_percent / 100.0;
            assert(st_coefficients(factor, hz, &a, &g) == 0);
            assert_stable(a, g, hz);
            assert(st_coefficients(factor, 120, &a, &g) == 0);
            assert_stable(a, g, hz);
        }
    }
    assert(st_coefficients(0.5, 120, &a, &g) == 0);
    for (unsigned i = 0; i < sizeof rates / sizeof *rates; ++i) {
        const double ratio = settle_time(a, g, rates[i]) /
                             settle_time(0.695, 2.0, rates[i]);
        printf("%.0f Hz: simulated 0.5 factor settling ratio %.3f\n", rates[i], ratio);
        assert(ratio > 0.40 && ratio < 0.65);
    }
    puts("Timing tests passed.");
    return 0;
}
