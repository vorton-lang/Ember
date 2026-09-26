// Negative test: default handler body uses an effect without a default handler.
// Effect WithDefault's body calls custom_op from effect Custom, which has no default.
// Should produce E0409 (default handler body uses effect without default handler).

effect Custom {
    fn custom_op() -> Int
}

effect WithDefault {
    fn wd_op() -> Int { Custom.custom_op() }
}
