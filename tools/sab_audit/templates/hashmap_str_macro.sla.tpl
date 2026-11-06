@import "sa_std/vec.sa"
@import "sa_std/hashmap.sa"
@import "sa_std/string.sa"
@import "sa_std/core/option.sa"

@test "sab audit probe"() {
    let m = HashMap::new();
    m.insert("a", 1);
    m.insert("b", 2);
    {{BODY}}
}
