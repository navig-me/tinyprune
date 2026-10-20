fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let exit = tinyprune_cli::run(
        &args,
        &mut std::io::stdin().lock(),
        &mut std::io::stdout().lock(),
        &mut std::io::stderr().lock(),
        tinyprune_cli::connect_local,
    );
    std::process::exit(exit);
}
