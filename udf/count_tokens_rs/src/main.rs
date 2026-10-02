//! count_tokens — a ClickHouse Cloud executable UDF, Native runtime (Rust).
//!
//! Deploy as: type = executable_pool, runtime = Native, format = RowBinary,
//! send_chunk_header = true, deterministic = true.
//!
//! Arguments: (model String, text String) -> UInt32
//!
//! Wire protocol (what ClickHouse sends on stdin / expects on stdout):
//!   1. A chunk header: the row count as decimal text, then '\n'.
//!   2. N RowBinary rows: each String is a LEB128 length followed by raw bytes.
//!   3. We answer with N UInt32 values, little-endian, and flush once per chunk.
//!   4. Repeat until stdin closes. The process is long-lived (pool).
use std::collections::HashMap;
use std::io::{self, BufRead, BufReader, BufWriter, Read, Write};
use std::path::PathBuf;
use std::process;

use serde::Deserialize;
use tiktoken_rs::{cl100k_base, o200k_base, CoreBPE};

/// models.json ships next to the binary in the zip. It lets you map new model
/// names to an encoding without recompiling.
#[derive(Deserialize)]
struct ModelRule {
    prefix: String,
    encoding: String,
}

/// Data files are deployed next to the binary, but the sandbox does not start
/// the process in that directory (the working directory is `/`, the bundle is
/// under `/scripts`), so resolve paths relative to the executable, never to cwd.
fn data_file(name: &str) -> PathBuf {
    let exe = std::env::current_exe()
        .ok()
        .or_else(|| std::env::args().next().map(PathBuf::from));
    match exe.as_deref().and_then(|p| p.parent()) {
        Some(dir) if !dir.as_os_str().is_empty() => dir.join(name),
        _ => PathBuf::from(name),
    }
}

struct Tokenizers {
    rules: Vec<ModelRule>,
    encoders: HashMap<&'static str, CoreBPE>,
}

impl Tokenizers {
    fn load() -> Self {
        let path = data_file("models.json");
        // Fail loudly: the zip always contains models.json, so a missing file
        // means the deployment is wrong, not that there are no rules.
        let raw = std::fs::read_to_string(&path)
            .unwrap_or_else(|e| die(&format!("cannot read {}: {e}", path.display())));
        let mut rules: Vec<ModelRule> =
            serde_json::from_str(&raw).unwrap_or_else(|e| die(&format!("bad {}: {e}", path.display())));
        rules.sort_by_key(|r| std::cmp::Reverse(r.prefix.len())); // longest prefix wins
        Self { rules, encoders: HashMap::new() }
    }

    fn encoding_for(&self, model: &str) -> &'static str {
        if let Some(r) = self.rules.iter().find(|r| model.starts_with(&r.prefix)) {
            return match r.encoding.as_str() {
                "cl100k_base" => "cl100k_base",
                _ => "o200k_base",
            };
        }
        // Models we don't recognise get o200k_base. That is an approximation for
        // non-OpenAI tokenizers; see the blog post for how we handle those.
        "o200k_base"
    }

    fn count(&mut self, model: &str, text: &str) -> u32 {
        let name = self.encoding_for(model);
        let bpe = self.encoders.entry(name).or_insert_with(|| {
            let r = if name == "cl100k_base" { cl100k_base() } else { o200k_base() };
            r.unwrap_or_else(|e| die(&format!("loading {name}: {e}")))
        });
        bpe.encode_ordinary(text).len() as u32
    }
}

fn die(msg: &str) -> ! {
    eprintln!("count_tokens: {msg}"); // stderr is surfaced in the ClickHouse error
    process::exit(1)
}

fn read_uvarint(r: &mut impl Read) -> io::Result<u64> {
    let (mut result, mut shift) = (0u64, 0u32);
    loop {
        let mut b = [0u8; 1];
        r.read_exact(&mut b)?;
        result |= ((b[0] & 0x7f) as u64) << shift;
        if b[0] < 0x80 {
            return Ok(result);
        }
        shift += 7;
    }
}

fn read_string(r: &mut impl Read, buf: &mut Vec<u8>) -> io::Result<()> {
    let n = read_uvarint(r)? as usize;
    buf.resize(n, 0);
    r.read_exact(buf)
}

fn main() {
    let mut tok = Tokenizers::load(); // reads models.json from the binary's directory
    let mut stdin = BufReader::with_capacity(1 << 20, io::stdin().lock());
    let mut stdout = BufWriter::with_capacity(1 << 20, io::stdout().lock());
    let (mut header, mut model, mut text) = (String::new(), Vec::new(), Vec::new());

    loop {
        // 1. chunk header: row count as decimal text + '\n' (send_chunk_header)
        header.clear();
        match stdin.read_line(&mut header) {
            Ok(0) => return, // pipe closed; pool process exits cleanly
            Ok(_) => {}
            Err(e) => die(&format!("reading chunk header: {e}")),
        }
        let rows: usize = header.trim().parse().unwrap_or_else(|_| die("bad chunk header"));

        // 2. N RowBinary rows: each String is a LEB128 length + raw bytes
        for i in 0..rows {
            read_string(&mut stdin, &mut model)
                .and_then(|_| read_string(&mut stdin, &mut text))
                .unwrap_or_else(|e| die(&format!("row {i}: {e}")));
            let n = tok.count(&String::from_utf8_lossy(&model), &String::from_utf8_lossy(&text));
            stdout.write_all(&n.to_le_bytes()).unwrap_or_else(|_| process::exit(1));
        }
        // 3. N UInt32 answers, flushed once per chunk
        stdout.flush().unwrap_or_else(|_| process::exit(1));
    }
}
