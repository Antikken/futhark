-- Rounding floats to whole numbers.
-- ==
-- input { [1.0000000000000002f64, -0.9999999999999999f64, -0.5000000000000001f64, -0f64, 0.49999999999999994f64, 0.5f64, 0.5000000000000001f64,
--          1.390671161567e-309f64, 2.2517998136852485e+15f64, 4.503599627370497e+15f64,
--          -f64.inf, f64.inf, f64.nan, -0f64]  } 
-- output { [2f64, 0f64, -0f64, -0f64, 1f64, 1f64, 1f64,
--           1f64, 2.251799813685249e+15f64, 4.503599627370497e+15f64,
--           -f64.inf, f64.inf, f64.nan, -0f64] }

def main = map f64.ceil
