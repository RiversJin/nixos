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
    sensor_fallback: Option<u8>,
    healthy_since: Option<u64>,
    recovery_ramp: bool,
}
impl Policy {
    pub fn new(minimum: u8) -> Self {
        Self {
            minimum,
            last_change: 0,
            gpu_assist: minimum,
            gpu_since: None,
            gpu_hold_until: 0,
            sensor_fallback: None,
            healthy_since: None,
            recovery_ramp: false,
        }
    }
    pub fn sensor_fault(&mut self, fallback: u8) {
        self.sensor_fallback = Some(fallback);
        self.healthy_since = None;
        self.recovery_ramp = false;
    }
    pub fn sensor_fault_latched(&self) -> bool {
        self.sensor_fallback.is_some()
    }
    pub fn recovery_phase(&self) -> Option<&'static str> {
        if self.sensor_fault_latched() {
            Some("sensor-recovering")
        } else if self.recovery_ramp {
            Some("sensor-recovery-ramp")
        } else {
            None
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
    pub fn stop_target(
        &self,
        temp: f64,
        gpu_request: u8,
        gpu_protection: u8,
        quiet: bool,
        current: u8,
        fallback: u8,
    ) -> (u8, &'static str) {
        // There will be no feedback after disconnecting. Never lower airflow
        // on exit, and cover demand that the running loop was still ramping to.
        let target = current
            .max(self.switch_request(temp, quiet))
            .max(self.gpu_assist)
            .max(gpu_request)
            .max(gpu_protection);
        if temp >= 75. || gpu_protection > 0 {
            return (target.max(fallback), "stopped-thermal-protection");
        }
        if self.sensor_fault_latched() {
            return (target.max(fallback), "stopped-sensor-recovery");
        }
        (
            target,
            if target > current {
                "stopped-demand"
            } else {
                "stopped-hold"
            },
        )
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
        // Called only after a successful complete sensor sample. Any new fault
        // resets this healthy window, including one during the recovery ramp.
        if self.sensor_fault_latched() {
            let since = *self.healthy_since.get_or_insert(now);
            if now.saturating_sub(since) >= 60 {
                self.sensor_fallback = None;
                self.healthy_since = None;
                self.recovery_ramp = true;
            }
        }
        if temp >= 90. || gpu_protection >= 100 {
            return 100;
        }
        if let Some(fallback) = self.sensor_fallback {
            return current.max(fallback).max(target);
        }
        if temp >= 80. || gpu_protection >= 80 {
            return target.max(80).max(current);
        }
        if self.recovery_ramp {
            // Bound every recovery step by both the held assistance and the
            // current GPU demand, even before its ordinary 20-second filter.
            let recovery_target = target.max(gpu_request);
            if current <= recovery_target {
                self.recovery_ramp = false;
            } else if now.saturating_sub(self.last_change) >= 5 {
                return recovery_target.max(current.saturating_sub(10));
            } else {
                return current;
            }
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
    fn normal_stop_keeps_recovered_pwm_instead_of_replaying_old_fallback() {
        let mut p = Policy::new(30);
        p.sensor_fault(100);
        p.decide(0, 50., 30, 0, true, 100);
        let mut current = 100;
        for now in (60..=90).step_by(5) {
            current = p.decide(now, 50., 30, 0, true, current);
            p.last_change = now;
            // Stopping partway through recovery must retain its current speed.
            assert_eq!(
                p.stop_target(50., 30, 0, true, current, 100),
                (current, "stopped-hold")
            );
        }
        assert_eq!(current, 30);
        assert_eq!(
            p.stop_target(50., 30, 0, true, current, 100),
            (30, "stopped-hold")
        );
        assert_eq!(p.stop_target(50., 30, 0, true, 50, 100).0, 50);
    }
    #[test]
    fn normal_stop_covers_fresh_and_held_demand_without_rise_delay() {
        let mut p = Policy::new(30);
        assert_eq!(
            p.stop_target(50., 70, 0, true, 30, 100),
            (70, "stopped-demand")
        );
        assert_eq!(p.stop_target(70., 30, 0, true, 30, 100).0, 45);
        assert_eq!(p.stop_target(50., 30, 0, false, 30, 100).0, 35);
        p.gpu_assist = 65;
        assert_eq!(p.stop_target(50., 30, 0, true, 30, 100).0, 65);
    }
    #[test]
    fn normal_stop_keeps_thermal_and_unresolved_sensor_protection() {
        let mut p = Policy::new(30);
        assert_eq!(
            p.stop_target(75., 30, 0, true, 30, 100),
            (100, "stopped-thermal-protection")
        );
        assert_eq!(p.stop_target(50., 80, 80, true, 30, 100).0, 100);
        assert_eq!(p.stop_target(90., 30, 0, true, 30, 80).0, 100);
        assert_eq!(p.stop_target(50., 100, 100, true, 30, 80).0, 100);
        p.sensor_fault(100);
        p.decide(0, 50., 30, 0, true, 100);
        p.decide(59, 50., 30, 0, true, 100);
        assert_eq!(
            p.stop_target(50., 30, 0, true, 30, 100),
            (100, "stopped-sensor-recovery")
        );
    }
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
    fn sensor_recovery_requires_healthy_window_then_finishes_in_bounded_steps() {
        let mut p = Policy::new(30);
        p.sensor_fault(100);
        assert_eq!(p.decide(0, 47., 30, 0, true, 100), 100);
        assert_eq!(p.decide(59, 47., 30, 0, true, 100), 100);
        assert_eq!(p.recovery_phase(), Some("sensor-recovering"));
        assert_eq!(p.decide(59, 81., 30, 80, true, 80), 100);
        let mut current = 100;
        for now in (60..=90).step_by(5) {
            let next = p.decide(now, 47., 30, 0, true, current);
            assert_eq!(next, current - 10);
            p.last_change = now;
            current = next;
            if now < 90 {
                assert_eq!(p.decide(now + 4, 47., 30, 0, true, current), current);
            }
        }
        assert_eq!(current, 30);
        assert_eq!(p.decide(95, 47., 30, 0, true, current), 30);
        assert_eq!(p.recovery_phase(), None);
        // Completion restores ordinary quiet-operation descent, not fast decay.
        assert_eq!(p.decide(100, 47., 30, 0, true, 60), 60);
        assert_eq!(p.decide(150, 47., 30, 0, true, 60), 58);
    }
    #[test]
    fn a_new_sensor_fault_restarts_the_entire_healthy_window() {
        let mut p = Policy::new(30);
        p.sensor_fault(100);
        p.decide(0, 47., 30, 0, true, 100);
        assert_eq!(p.decide(60, 47., 30, 0, true, 100), 90);
        p.last_change = 60;
        p.sensor_fault(100);
        assert_eq!(p.decide(65, 47., 30, 0, true, 100), 100);
        assert_eq!(p.decide(124, 47., 30, 0, true, 100), 100);
        assert_eq!(p.decide(125, 47., 30, 0, true, 100), 90);
        // Repeated failures before recovery also reset the window.
        p.sensor_fault(100);
        p.decide(130, 47., 30, 0, true, 100);
        p.sensor_fault(100);
        assert_eq!(p.decide(189, 47., 30, 0, true, 100), 100);
        assert_eq!(p.decide(248, 47., 30, 0, true, 100), 100);
        assert_eq!(p.decide(249, 47., 30, 0, true, 100), 90);
    }
    #[test]
    fn recovery_respects_new_gpu_demand_and_immediate_thermal_guards() {
        let mut p = Policy::new(30);
        p.sensor_fault(100);
        p.decide(0, 47., 30, 0, true, 100);
        assert_eq!(p.decide(60, 47., 30, 0, true, 100), 90);
        p.last_change = 60;
        assert_eq!(p.decide(65, 47., 75, 0, true, 90), 80);
        p.last_change = 65;
        assert_eq!(p.gpu_assist, 30); // Current demand is not filtered away.
        assert_eq!(p.decide(70, 47., 75, 0, true, 80), 75);
        assert_eq!(p.decide(71, 47., 30, 80, true, 75), 80);
        assert_eq!(p.decide(72, 47., 30, 100, true, 75), 100);
        assert_eq!(p.decide(73, 90., 30, 0, true, 75), 100);
        assert_eq!(p.decide(74, 81., 30, 0, true, 90), 90);
        // Switch/away demand is another hard lower bound on fast descent.
        let mut away = Policy::new(30);
        away.sensor_fault(100);
        away.decide(0, 65., 30, 0, false, 100);
        let mut current = 100;
        for now in (60..=90).step_by(5) {
            current = away.decide(now, 65., 30, 0, false, current);
            away.last_change = now;
            assert!(current >= 45);
        }
        assert_eq!(current, 45);
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
