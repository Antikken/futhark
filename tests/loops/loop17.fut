-- ==
-- input { 5i16 } output { 5i16 }
-- structure { DoLoop/ConvOp 1 }

-- Since narrowLoopType has been disabled, this optimization no longer works.

def main (x: i16) =
  loop x = 0 for i in -x..<x do
    x - i
