@import "sa_std/vec.sa"

@test "sab audit probe"() {
    let vb: Vec<u8> = Vec::new();
    vb.push(104);
    vb.push(105);
    {{BODY}}
}
