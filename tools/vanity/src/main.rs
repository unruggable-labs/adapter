//! CREATE2 leading-zeros vanity miner.
//!
//! Computes `address = keccak256(0xff ++ deployer ++ salt ++ init_code_hash)[12:]`
//! over many random salts in parallel and tracks the salt that yields the most
//! leading zero nibbles. Time-boxed: run for a budget, note the best, re-run
//! with a bigger budget to push for one more zero (~16x work per extra nibble).

use clap::Parser;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tiny_keccak::{Hasher, Keccak};

#[derive(Parser, Debug)]
#[command(about = "CREATE2 leading-zeros vanity miner")]
struct Args {
    /// CREATE2 deployer / factory address (20-byte hex, 0x optional)
    #[arg(long)]
    deployer: String,

    /// init code hash: keccak256 of the contract init (creation) code (32-byte hex)
    #[arg(long)]
    init_code_hash: String,

    /// Time budget in seconds (start at 180; 10x to 1800 to push for more zeros)
    #[arg(long, default_value_t = 180)]
    seconds: u64,

    /// Stop early once this many leading zero nibbles is reached (0 = run full budget)
    #[arg(long, default_value_t = 0)]
    target_nibbles: u32,

    /// Worker threads (0 = all available cores)
    #[arg(long, default_value_t = 0)]
    threads: usize,
}

fn parse_hex<const N: usize>(s: &str, what: &str) -> [u8; N] {
    let s = s.strip_prefix("0x").unwrap_or(s);
    let bytes = hex::decode(s).unwrap_or_else(|_| panic!("{what}: invalid hex"));
    assert_eq!(bytes.len(), N, "{what}: expected {N} bytes, got {}", bytes.len());
    let mut out = [0u8; N];
    out.copy_from_slice(&bytes);
    out
}

#[inline(always)]
fn leading_zero_nibbles(addr: &[u8; 20]) -> u32 {
    let mut n = 0u32;
    for &b in addr {
        if b == 0 {
            n += 2;
        } else if b < 0x10 {
            n += 1;
            break;
        } else {
            break;
        }
    }
    n
}

fn main() {
    let args = Args::parse();
    let deployer = parse_hex::<20>(&args.deployer, "deployer");
    let ich = parse_hex::<32>(&args.init_code_hash, "init-code-hash");
    let threads = if args.threads == 0 {
        std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4)
    } else {
        args.threads
    };

    println!("deployer        0x{}", hex::encode(deployer));
    println!("init code hash  0x{}", hex::encode(ich));
    println!("threads         {threads}");
    println!("budget          {}s", args.seconds);
    if args.target_nibbles > 0 {
        println!("target          {} leading-zero nibbles (stop early)", args.target_nibbles);
    }
    println!("mining...\n");

    let start = Instant::now();
    let deadline = start + Duration::from_secs(args.seconds);
    let best_nibbles = Arc::new(AtomicU32::new(0));
    let best = Arc::new(Mutex::new(([0u8; 32], [0u8; 20], 0u32)));
    let total = Arc::new(AtomicU64::new(0));
    let stop = Arc::new(AtomicBool::new(false));

    let seed = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() as u64;

    let mut handles = Vec::new();
    for tid in 0..threads {
        let best_nibbles = best_nibbles.clone();
        let best = best.clone();
        let total = total.clone();
        let stop = stop.clone();
        let target = args.target_nibbles;
        handles.push(std::thread::spawn(move || {
            // buf layout: 0xff(1) ++ deployer(20) ++ salt(32) ++ init_code_hash(32) = 85 bytes
            let mut buf = [0u8; 85];
            buf[0] = 0xff;
            buf[1..21].copy_from_slice(&deployer);
            buf[53..85].copy_from_slice(&ich);

            // salt = seed(8) ++ tid(8) ++ 0(8) ++ counter(8); disjoint per thread/run
            let mut salt = [0u8; 32];
            salt[0..8].copy_from_slice(&seed.to_be_bytes());
            salt[8..16].copy_from_slice(&(tid as u64).to_be_bytes());

            let mut counter: u64 = 0;
            let mut local: u64 = 0;
            let mut out = [0u8; 32];
            loop {
                salt[24..32].copy_from_slice(&counter.to_be_bytes());
                buf[21..53].copy_from_slice(&salt);

                let mut k = Keccak::v256();
                k.update(&buf);
                k.finalize(&mut out);

                let addr: [u8; 20] = out[12..32].try_into().unwrap();
                let z = leading_zero_nibbles(&addr);
                if z > best_nibbles.load(Ordering::Relaxed) {
                    let mut b = best.lock().unwrap();
                    if z > b.2 {
                        *b = (salt, addr, z);
                        best_nibbles.store(z, Ordering::Relaxed);
                        let elapsed = start.elapsed().as_secs_f64();
                        println!(
                            "[+] {z:>2} zero nibbles ({} zero bytes)  0x{}  salt 0x{}  (+{elapsed:.0}s)",
                            z / 2,
                            hex::encode(addr),
                            hex::encode(salt),
                        );
                        if target > 0 && z >= target {
                            stop.store(true, Ordering::Relaxed);
                        }
                    }
                }

                counter = counter.wrapping_add(1);
                local += 1;
                if local & 0xFFFFF == 0 {
                    total.fetch_add(0x100000, Ordering::Relaxed);
                    if stop.load(Ordering::Relaxed) || Instant::now() >= deadline {
                        break;
                    }
                }
            }
        }));
    }

    // monitor: live hash rate every 15s
    {
        let total = total.clone();
        let stop = stop.clone();
        std::thread::spawn(move || loop {
            std::thread::sleep(Duration::from_secs(15));
            if stop.load(Ordering::Relaxed) || Instant::now() >= deadline {
                break;
            }
            let attempts = total.load(Ordering::Relaxed);
            let secs = start.elapsed().as_secs_f64();
            eprintln!(
                "    {:.1}s  {:.0}M attempts  {:.1} Mhash/s",
                secs,
                attempts as f64 / 1e6,
                attempts as f64 / secs / 1e6
            );
        });
    }

    for h in handles {
        let _ = h.join();
    }

    let (salt, addr, z) = *best.lock().unwrap();
    let attempts = total.load(Ordering::Relaxed);
    let secs = start.elapsed().as_secs_f64();
    println!("\n=== best ===");
    println!("address         0x{}", hex::encode(addr));
    println!("salt            0x{}", hex::encode(salt));
    println!("leading zeros   {z} nibbles ({} bytes)", z / 2);
    println!("attempts        {attempts} ({:.0}M)", attempts as f64 / 1e6);
    println!("elapsed         {secs:.1}s  ({:.1} Mhash/s)", attempts as f64 / secs / 1e6);
}
