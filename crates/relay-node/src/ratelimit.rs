//! Token bucket rate limiting, per client IP.

use std::collections::HashMap;
use std::net::IpAddr;
use std::sync::Mutex;
use std::time::Instant;

/// One token bucket.
#[derive(Debug, Clone)]
pub struct Bucket {
    tokens: f64,
    last: Instant,
}

impl Bucket {
    pub fn new(burst: f64) -> Self {
        Self { tokens: burst, last: Instant::now() }
    }

    /// Refills at `rate` tokens per second up to `burst`, then takes `cost` if available.
    pub fn take(&mut self, cost: f64, rate: f64, burst: f64) -> bool {
        let now = Instant::now();
        let elapsed = now.duration_since(self.last).as_secs_f64();
        self.last = now;
        self.tokens = (self.tokens + elapsed * rate).min(burst);
        if self.tokens >= cost {
            self.tokens -= cost;
            true
        } else {
            false
        }
    }
}

/// A map of buckets keyed by IP address.
pub struct IpLimiter {
    rate: f64,
    burst: f64,
    buckets: Mutex<HashMap<IpAddr, Bucket>>,
}

impl IpLimiter {
    pub fn new(rate: f64, burst: f64) -> Self {
        Self { rate, burst, buckets: Mutex::new(HashMap::new()) }
    }

    /// Returns `true` when the request from `ip` is allowed.
    pub fn check(&self, ip: IpAddr) -> bool {
        if self.rate <= 0.0 {
            return true;
        }
        let mut map = self.buckets.lock().unwrap();
        let b = map.entry(ip).or_insert_with(|| Bucket::new(self.burst));
        b.take(1.0, self.rate, self.burst)
    }

    /// Drops buckets that are full again, so the map does not grow without bound.
    pub fn prune(&self) {
        let (rate, burst) = (self.rate, self.burst);
        let mut map = self.buckets.lock().unwrap();
        map.retain(|_, b| {
            let mut probe = b.clone();
            !probe.take(burst, rate, burst)
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bucket_runs_dry() {
        let l = IpLimiter::new(0.001, 3.0);
        let ip: IpAddr = "10.0.0.1".parse().unwrap();
        assert!(l.check(ip) && l.check(ip) && l.check(ip));
        assert!(!l.check(ip));
        let other: IpAddr = "10.0.0.2".parse().unwrap();
        assert!(l.check(other));
    }
}
