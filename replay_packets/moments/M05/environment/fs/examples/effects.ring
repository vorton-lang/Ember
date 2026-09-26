// Ring-lang: Effect system demo

struct Config {
    host: Str,
    port: Int,
}

fn load_config(path: Str) -> Config {
    let raw = io.read(path)
    Config { host: raw, port: 8080 }
}

fn get_config() -> Config {
    load_config("custom.toml") or Config { host: "localhost", port: 3000 }
}

test "effect handler mock" {
    handle {
        let raw = io.read("test.toml")
        assert(raw == "mock data", "mock read")
    } with {
        io.read(_path) => "mock data",
    }
}

fn main() {
    handle {
        let config = get_config()
        print("Server at ${config.host}:${config.port}")
    } with {
        io.read(_path) => "fallback",
        fail.raise(e) => panic("failed"),
    }
}
