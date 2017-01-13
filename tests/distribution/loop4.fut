-- Distribution with maps consuming their input.
--
-- ==
--
-- structure distributed { Map/Loop 0 }

fun main(m: int, a: [n][k]int): [n][k]int =
  map (\(a_r: [k]int): [k]int  ->
        let a_r_copy = copy(a_r) in
        loop(acc = a_r_copy) = for i < m do
          let acc' = copy(map (+) acc (a_r))
          let acc'[0] = 0 in
          acc' in
        acc
     ) a
