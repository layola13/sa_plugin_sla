struct BundleManifest {
    binary: bool,
    config: bool,
    checksums: bool,
}

fn release_ready(manifest: BundleManifest) -> bool {
    manifest.binary && manifest.config && manifest.checksums
}

fn main() {
    let manifest = BundleManifest { binary: true, config: true, checksums: true };
    println!("{}", release_ready(manifest));
}
