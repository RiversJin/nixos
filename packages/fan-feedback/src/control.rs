pub fn interpolate(value: f64, points: &[(f64, u8)]) -> u8 {
    for pair in points.windows(2) {
        let [(low, a), (high, b)] = pair else {
            unreachable!()
        };
        if value <= *low {
            return *a;
        }
        if value < *high {
            return (f64::from(*a) + (value - low) / (high - low) * f64::from(b - a)).round() as u8;
        }
    }
    points.last().unwrap().1
}

pub struct Policy {
    pub minimum: u8,
    pub last_change: u64,
    pub gpu_assist: u8,
    gpu_since: Option<u64>,
    gpu_hold_until: u64,
}
impl Policy {
    pub fn new(minimum: u8) -> Self {
        Self {
            minimum,
            last_change: 0,
            gpu_assist: minimum,
            gpu_since: None,
            gpu_hold_until: 0,
        }
    }
    pub fn switch_request(&self, temp: f64, quiet: bool) -> u8 {
        if quiet {
            interpolate(
                temp,
                &[
                    (65., self.minimum),
                    (70., 45),
                    (75., 65),
                    (80., 80),
                    (90., 100),
                ],
            )
        } else {
            interpolate(
                temp,
                &[
                    (55., self.minimum.max(35)),
                    (65., 45),
                    (75., 65),
                    (80., 80),
                    (90., 100),
                ],
            )
        }
    }
    pub fn decide(
        &mut self,
        now: u64,
        temp: f64,
        gpu_request: u8,
        gpu_protection: u8,
        quiet: bool,
        current: u8,
    ) -> u8 {
        if gpu_request > self.minimum {
            let since = *self.gpu_since.get_or_insert(now);
            if now.saturating_sub(since) >= 20
                && (gpu_request >= self.gpu_assist || now >= self.gpu_hold_until)
            {
                self.gpu_assist = gpu_request;
                self.gpu_hold_until = now + 120;
            }
        } else {
            self.gpu_since = None;
            if now >= self.gpu_hold_until {
                self.gpu_assist = self.minimum;
            }
        }
        let target = self
            .switch_request(temp, quiet)
            .max(self.gpu_assist)
            .max(gpu_protection);
        if temp >= 90. || gpu_protection >= 100 {
            return 100;
        }
        if temp >= 80. || gpu_protection >= 80 {
            return target.max(80).max(current);
        }
        if target > current && (target >= current.saturating_add(3) || current < self.minimum) {
            if now.saturating_sub(self.last_change) >= 15 {
                return target.min(current.saturating_add(5)).max(self.minimum);
            }
        } else if (target.saturating_add(3) < current
            || (target == self.minimum && current > target))
            && now.saturating_sub(self.last_change) >= 60
        {
            return target.max(current.saturating_sub(2));
        }
        current.max(self.minimum)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn protections_override_noise_and_rate_limits() {
        let mut p = Policy::new(35);
        p.last_change = 100;
        assert_eq!(p.decide(101, 90., 35, 0, true, 35), 100);
        assert_eq!(p.decide(101, 81., 35, 0, true, 35), 82);
        assert_eq!(p.decide(101, 56., 35, 100, true, 35), 100);
        assert_eq!(p.decide(101, 56., 35, 80, true, 35), 80);
    }
    #[test]
    fn agreed_switch_curve() {
        let p = Policy::new(30);
        for (t, v) in [(64., 30), (70., 45), (75., 65), (80., 80), (90., 100)] {
            assert_eq!(p.switch_request(t, true), v);
        }
        assert!(p.switch_request(60., false) > p.switch_request(60., true));
        assert_eq!(p.switch_request(40., false), 35);
        let mut p = Policy::new(30);
        assert_eq!(p.decide(60, 56., 30, 0, true, 33), 31);
        assert_eq!(p.decide(120, 56., 30, 0, true, 31), 30);
    }
    #[test]
    fn gpu_spikes_filtered_and_cooldown_expires() {
        let mut p = Policy::new(35);
        assert_eq!(p.decide(100, 56., 55, 0, true, 35), 35);
        assert_eq!(p.decide(110, 56., 35, 0, true, 35), 35);
        assert_eq!(p.decide(200, 56., 55, 0, true, 35), 35);
        assert_eq!(p.decide(220, 56., 55, 0, true, 35), 40);
        assert_eq!(p.gpu_assist, 55);
        p.decide(300, 56., 35, 0, true, 55);
        assert_eq!(p.gpu_assist, 55);
        assert_eq!(p.decide(341, 56., 35, 0, true, 55), 53);
        assert_eq!(p.gpu_assist, 35);
    }
    #[test]
    fn sustained_lower_gpu_request_releases_old_peak() {
        let mut p = Policy::new(35);
        p.decide(100, 56., 70, 0, true, 35);
        p.decide(120, 56., 70, 0, true, 35);
        p.decide(200, 56., 45, 0, true, 70);
        assert_eq!(p.gpu_assist, 70);
        p.decide(241, 56., 45, 0, true, 70);
        assert_eq!(p.gpu_assist, 45);
    }
    #[test]
    fn slow_decrease_and_deadband() {
        let mut p = Policy::new(35);
        p.last_change = 100;
        assert_eq!(p.decide(130, 56., 35, 0, true, 40), 40);
        assert_eq!(p.decide(160, 56., 35, 0, true, 40), 38);
        assert_eq!(p.decide(160, 56., 35, 0, true, 37), 35);
    }
}
