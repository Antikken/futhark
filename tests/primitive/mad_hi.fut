-- Test u8.mad_hi
-- ==
-- entry: test_u8_mad_hi
-- input  { [10u8, 20u8, 2u8, 1u8, 2u8, 3u8, 2u8, 8u8 ]
--          [10u8, 20u8, 127u8, 255u8, 255u8, 127u8, 128u8, 128u8]
--          [0u8, 1u8, 2u8, 3u8, 4u8, 5u8, 7u8, 255u8] }
-- output { [0u8, 2u8, 2u8, 3u8, 5u8, 6u8, 8u8, 3u8] }

entry test_u8_mad_hi = map3 u8.mad_hi

-- Test i8.mad_hi
-- ==
-- entry: test_i8_mad_hi
-- input  { [10i8, 20i8,   2i8,  1i8,  2i8,   3i8,   2i8,  13i8]
--          [10i8, 20i8, 127i8, -1i8, -1i8, 127i8, 128i8, 128i8]
--          [ 0i8,  1i8,   2i8,  3i8,  4i8,   5i8,   6i8, 255i8] }
-- output { [0i8,   2i8,   2i8,  2i8,  3i8,   6i8,   5i8,  -8i8] }

entry test_i8_mad_hi = map3 i8.mad_hi

-- Test u16.mad_hi
-- ==
-- entry: test_u16_mad_hi
-- input  { [10u16, 20u16, 2u16, 3u16, 2u16, 1u16, 2u16, 2u16, 2u16, 3u16, 65535u16]
--          [10u16, 20u16, 127u16, 127u16, 128u16, 255u16, 255u16, 32768u16, 65535u16, 65535u16, 65535u16]
--          [1u16, 2u16, 3u16, 4u16, 5u16, 6u16, 7u16, 8u16, 9u16, 10u16, 11u16] }
-- output { [1u16, 2u16, 3u16, 4u16, 5u16, 6u16, 7u16, 9u16, 10u16, 12u16, 9u16] }

entry test_u16_mad_hi = map3 u16.mad_hi

-- Test i16.mad_hi
-- ==
-- entry: test_i16_mad_hi
-- input  { [ 10i16,  20i16,   2i16,    3i16,   2i16,   1i16,   2i16,     2i16,   2i16,   3i16,  -1i16]
--          [ 10i16,  20i16,  127i16, 127i16, 128i16, 255i16, 255i16, 32768i16,  -1i16,  -1i16,  -1i16]
--          [250i16, 251i16, 252i16,  253i16, 254i16, 255i16, 256i16,   257i16, 258i16, 259i16, 260i16] }
-- output { [250i16, 251i16, 252i16, 253i16, 254i16, 255i16, 256i16, 256i16, 257i16, 258i16, 260i16] }

entry test_i16_mad_hi = map3 i16.mad_hi

-- Test u32.mad_hi
-- ==
-- entry: test_u32_mad_hi
-- input  { [10u32, 20u32, 2u32, 3u32, 2u32, 1u32,2u32, 2u32, 2u32, 3u32, 65535u32, 1u32, 2u32, 5u32, 4294967295u32]
--          [10u32, 20u32, 127u32, 127u32, 128u32, 255u32, 255u32, 32768u32, 65535u32, 65535u32, 65535u32, 4294967295u32, 4294967295u32, 4294967295u32, 4294967295u32]
--          [1u32, 2u32, 3u32, 4u32, 5u32, 6u32, 7u32, 8u32, 9u32, 10u32, 11u32, 12u32, 13u32, 14u32, 15u32] }
-- output { [1u32, 2u32, 3u32, 4u32, 5u32, 6u32, 7u32, 8u32, 9u32, 10u32, 11u32, 12u32, 14u32, 18u32, 13u32] }

entry test_u32_mad_hi = map3 u32.mad_hi

-- Test i32.mad_hi
-- ==
-- entry: test_i32_mad_hi
-- input  { [10i32, 20i32,   2i32,   3i32,   2i32,   1i32,   2i32,     2i32,     2i32,     3i32, 65535i32,  1i32,  2i32,  5i32, -1i32]
--          [10i32, 20i32, 127i32, 127i32, 128i32, 255i32, 255i32, 32768i32, 65535i32, 65535i32, 65535i32, -1i32, -1i32, -1i32, -1i32]
--          [0i32,   0i32,   0i32,   0i32,   0i32,   0i32,   0i32,     0i32,     0i32,     0i32,     0i32,  0i32,  0i32,  0i32,  0i32] }
-- output { [0i32,   0i32,   0i32,   0i32,   0i32,   0i32,   0i32,     0i32,     0i32,     0i32,     0i32,  -1i32, -1i32,-1i32,   0i32] }

entry test_i32_mad_hi = map3 i32.mad_hi

-- Test u64.mad_hi
-- ==
-- entry: test_u64_mad_hi
-- input  { [10u64, 20u64, 2u64, 3u64, 2u64, 1u64, 2u64, 2u64, 2u64, 3u64, 65535u64, 1u64, 2u64, 5u64, 4294967295u64, 1u64, 2u64, 18446744073709551615u64]
--          [10u64, 20u64, 127u64, 127u64, 128u64, 255u64, 255u64, 32768u64, 65535u64, 65535u64, 65535u64, 4294967295u64, 4294967295u64, 4294967295u64, 4294967295u64, 18446744073709551615u64,18446744073709551615u64, 18446744073709551615u64]
--          [1u64, 2u64, 3u64, 4u64, 5u64, 6u64, 7u64, 8u64, 9u64, 10u64, 11u64, 12u64, 13u64, 14u64, 15u64, 16u64, 17u64, 18u64] }
-- output { [1u64, 2u64, 3u64, 4u64, 5u64, 6u64, 7u64, 8u64, 9u64, 10u64, 11u64, 12u64, 13u64, 14u64, 15u64, 16u64, 18u64, 16u64] }

entry test_u64_mad_hi = map3 u64.mad_hi

-- Test i64.mad_hi
-- ==
-- entry: test_i64_mad_hi
-- input  { [10i64, 20i64, 2i64, 3i64, 2i64, 1i64, 2i64, 2i64, 2i64, 3i64, 65535i64, 1i64, 2i64, 5i64, 4294967295i64, 1i64, 2i64, -1i64]
--          [10i64, 20i64, 127i64, 127i64, 128i64, 255i64, 255i64, 32768i64, 65535i64, 65535i64, 65535i64, 4294967295i64, 4294967295i64, 4294967295i64, 4294967295i64, -1i64, -1i64, -1i64]
--          [1i64, 2i64, 3i64, 4i64, 5i64, 6i64, 7i64, 8i64, 9i64, 10i64, 11i64, 12i64, 13i64, 14i64, 15i64, 16i64, 17i64, 18i64] }
-- output { [1i64, 2i64, 3i64, 4i64, 5i64, 6i64, 7i64, 8i64, 9i64, 10i64, 11i64, 12i64, 13i64, 14i64, 15i64, 15i64, 16i64, 18i64] }

entry test_i64_mad_hi = map3 i64.mad_hi
