-- This test fails with a DuplicateDefinition error.
-- ==
-- error: .*Dup.*

struct Foo
  {
    fun foo(): foo = 1
  }
type foo = int
type foo = float

fun main(): int = 0
