// Negative test: cyclic dependency between default effect handlers.
// Effect X's default body calls Y's op, and Y's default body calls X's op.
// Should produce E0410 (cyclic default effect handler dependency).

effect X {
    fn x_op() -> Int { Y.y_op() }
}

effect Y {
    fn y_op() -> Int { X.x_op() }
}
