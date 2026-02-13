use std::env;
use std::path::PathBuf;

fn main() {
    let crate_dir = env::var("CARGO_MANIFEST_DIR").unwrap();
    let output_dir = PathBuf::from(&crate_dir).join("..").join("pier-bridge").join("include");

    // Generate C header file for Swift FFI
    let config = cbindgen::Config {
        language: cbindgen::Language::C,
        braces: cbindgen::Braces::SameLine,
        style: cbindgen::Style::Both,
        ..Default::default()
    };

    cbindgen::Builder::new()
        .with_crate(crate_dir)
        .with_config(config)
        .generate()
        .expect("Unable to generate C bindings")
        .write_to_file(output_dir.join("pier_core.h"));
}
