@import "sa_std/hashset.sa"

@test "sab audit probe"() {
    let s = HashSet::new();
    s.insert("a");
    s.insert("b");
    {{BODY}}
}
