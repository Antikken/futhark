let main is js = map2(\i j -> reduce (+) 0 (iota 5 with [i:j] = iota (j-i))) is js