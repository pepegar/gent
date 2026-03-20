use janetrs::{client::JanetClient, env::CFunOptions, Janet, JanetBuffer, JanetString};
use sha2::{Digest, Sha256};

/// (crypto/sha256 data)
/// Compute SHA-256 hash of a string or buffer. Returns raw 32-byte hash as a buffer.
#[janetrs::janet_fn(arity(fix(1)))]
fn sha256(args: &mut [Janet]) -> Janet {
    let input: JanetString = args[0]
        .try_unwrap()
        .expect("crypto/sha256: argument must be a string or buffer");
    let mut hasher = Sha256::new();
    hasher.update(input.as_bytes());
    let result = hasher.finalize();
    let buf = JanetBuffer::from(result.as_slice());
    Janet::from(buf)
}

/// (crypto/random-bytes n)
/// Generate n cryptographically secure random bytes. Returns a buffer.
#[janetrs::janet_fn(arity(fix(1)))]
fn random_bytes(args: &mut [Janet]) -> Janet {
    let n: f64 = args[0]
        .try_unwrap()
        .expect("crypto/random-bytes: argument must be a number");
    let n = n as usize;
    let mut buf = vec![0u8; n];
    getrandom::getrandom(&mut buf).expect("crypto/random-bytes: failed to get random bytes");
    let jbuf = JanetBuffer::from(buf.as_slice());
    Janet::from(jbuf)
}

pub fn register(client: &mut JanetClient) {
    client.add_c_fn(CFunOptions::new(c"sha256", sha256_c).namespace(c"crypto"));
    client.add_c_fn(CFunOptions::new(c"random-bytes", random_bytes_c).namespace(c"crypto"));
}
