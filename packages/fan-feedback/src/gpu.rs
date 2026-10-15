use crate::{Result, control::interpolate};
use serde_json::{Value, json};
use std::{fs, path::Path, thread, time::Duration};

pub struct Gpu {
    pci: String,
    sample: Option<ActiveGpu>,
}
struct ActiveGpu {
    rpm: u32,
    max_rpm: u32,
    edge_c: f64,
    junction_c: f64,
    request: u8,
    protection: u8,
    busy: Option<u8>,
    power_w: Option<f64>,
}
#[derive(Clone, Copy)]
enum RuntimeState {
    Active,
    Suspended,
    Transitioning,
}
fn runtime_state(device: &Path) -> Result<RuntimeState> {
    let path = device.join("power/runtime_status");
    match fs::read_to_string(&path)?.trim() {
        "active" => Ok(RuntimeState::Active),
        "suspended" => Ok(RuntimeState::Suspended),
        "suspending" | "resuming" => Ok(RuntimeState::Transitioning),
        state => Err(format!("{}: unexpected runtime state {state:?}", path.display()).into()),
    }
}
fn number(path: &Path) -> Result<f64> {
    let n = fs::read_to_string(path)
        .map_err(|e| format!("{}: {e}", path.display()))?
        .trim()
        .parse::<f64>()?;
    if !n.is_finite() {
        return Err("non-finite GPU telemetry".into());
    }
    Ok(n)
}
impl ActiveGpu {
    fn read_at(device: &Path, p: &Path) -> Result<Self> {
        let rpm = number(&p.join("fan1_input"))?;
        let max = number(&p.join("fan1_max"))?;
        // Require labels to avoid silently swapping edge and junction readings.
        if fs::read_to_string(p.join("temp1_label"))?.trim() != "edge"
            || fs::read_to_string(p.join("temp2_label"))?.trim() != "junction"
        {
            return Err("unexpected GPU temperature labels".into());
        }
        let edge = number(&p.join("temp1_input"))? / 1000.;
        let junction = number(&p.join("temp2_input"))? / 1000.;
        if !(0. ..=20000.).contains(&rpm)
            || !(100. ..=20000.).contains(&max)
            || !(0. ..150.).contains(&edge)
            || !(0. ..150.).contains(&junction)
        {
            return Err("GPU telemetry outside valid limits".into());
        }
        let request = interpolate(
            rpm / max * 100.,
            &[
                (0., 30),
                (20., 30),
                (35., 45),
                (50., 55),
                (65., 70),
                (80., 85),
                (100., 100),
            ],
        )
        .max(interpolate(
            edge,
            &[(60., 30), (70., 45), (80., 80), (85., 100)],
        ))
        .max(interpolate(
            junction,
            &[(75., 30), (85., 50), (95., 80), (100., 100)],
        ));
        let protection = if edge >= 85. || junction >= 100. {
            100
        } else if edge >= 80. || junction >= 95. {
            80
        } else {
            0
        };
        Ok(Self {
            rpm: rpm as u32,
            max_rpm: max as u32,
            edge_c: edge,
            junction_c: junction,
            request,
            protection,
            busy: fs::read_to_string(device.join("gpu_busy_percent"))
                .ok()
                .and_then(|s| s.trim().parse::<u8>().ok())
                .filter(|b| *b <= 100),
            power_w: number(&p.join("power1_average"))
                .ok()
                .map(|p| p / 1_000_000.),
        })
    }
}
impl Gpu {
    fn read_at(root: &Path, pci: &str) -> Result<Self> {
        let device = root.join(pci);
        for entry in fs::read_dir(device.join("hwmon"))? {
            let p = entry?.path();
            if !fs::read_to_string(p.join("name")).is_ok_and(|s| s.trim() == "amdgpu") {
                continue;
            }
            return Self::sample(
                pci,
                || runtime_state(&device),
                || ActiveGpu::read_at(&device, &p),
            );
        }
        Err(format!("{pci}: amdgpu hwmon unavailable").into())
    }
    fn sample(
        pci: &str,
        mut state: impl FnMut() -> Result<RuntimeState>,
        mut read: impl FnMut() -> Result<ActiveGpu>,
    ) -> Result<Self> {
        // hwmon must exist before considering runtime suspend. Never infer
        // sleep from EBUSY alone: resets and broken sensors also return it.
        for attempt in 0..11 {
            match state()? {
                RuntimeState::Suspended => {
                    return Ok(Self {
                        pci: pci.into(),
                        sample: None,
                    });
                }
                RuntimeState::Active => {
                    let sample = read();
                    // The GPU can suspend between the state check and hwmon
                    // access. Recheck even after a failed read, without waking it.
                    match state()? {
                        RuntimeState::Suspended => {
                            return Ok(Self {
                                pci: pci.into(),
                                sample: None,
                            });
                        }
                        RuntimeState::Active => {
                            return sample.map(|sample| Self {
                                pci: pci.into(),
                                sample: Some(sample),
                            });
                        }
                        RuntimeState::Transitioning => {}
                    }
                }
                RuntimeState::Transitioning => {}
            }
            if attempt < 10 {
                thread::sleep(Duration::from_millis(50));
            }
        }
        Err("GPU runtime power transition did not settle within 500 ms".into())
    }
    fn request(&self) -> u8 {
        self.sample.as_ref().map_or(30, |s| s.request)
    }
    fn protection(&self) -> u8 {
        self.sample.as_ref().map_or(0, |s| s.protection)
    }
    pub fn json(&self) -> Value {
        let s = self.sample.as_ref();
        json!({"pci":self.pci,"runtime_status":if s.is_some() { "active" } else { "suspended" },
            "rpm":s.map(|s| s.rpm),"max_rpm":s.map(|s| s.max_rpm),"edge_c":s.map(|s| s.edge_c),
            "junction_c":s.map(|s| s.junction_c),"request_pwm":self.request(),"protection_pwm":self.protection(),
            "busy_percent":s.and_then(|s| s.busy),"power_w":s.and_then(|s| s.power_w)})
    }
}
pub fn read(devices: &[String]) -> Result<Vec<Gpu>> {
    devices
        .iter()
        .map(|pci| {
            Gpu::read_at(Path::new("/sys/bus/pci/devices"), pci)
                .map_err(|e| format!("GPU {pci}: {e}").into())
        })
        .collect()
}
pub fn request(gpus: &[Gpu]) -> u8 {
    gpus.iter().map(Gpu::request).max().unwrap_or(30)
}
pub fn protection(gpus: &[Gpu]) -> u8 {
    gpus.iter().map(Gpu::protection).max().unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn hot_sample() -> ActiveGpu {
        ActiveGpu {
            rpm: 0,
            max_rpm: 3200,
            edge_c: 85.,
            junction_c: 100.,
            request: 100,
            protection: 100,
            busy: None,
            power_w: None,
        }
    }
    #[test]
    fn suspended_gpu_has_no_invented_readings_and_resume_requires_sensors() {
        let root = std::env::temp_dir().join(format!("fan-feedback-sleep-{}", std::process::id()));
        let device = root.join("test");
        let p = device.join("hwmon/hwmon9");
        fs::create_dir_all(&p).unwrap();
        fs::create_dir_all(device.join("power")).unwrap();
        fs::write(p.join("name"), "amdgpu").unwrap();
        fs::write(device.join("power/runtime_status"), "suspended").unwrap();
        let sleeping = Gpu::read_at(&root, "test").unwrap();
        assert_eq!(sleeping.request(), 30);
        assert_eq!(sleeping.protection(), 0);
        assert_eq!(
            crate::control::Policy::new(30).decide(
                0,
                90.,
                request(std::slice::from_ref(&sleeping)),
                protection(std::slice::from_ref(&sleeping)),
                true,
                30
            ),
            100
        );
        let value = sleeping.json();
        assert_eq!(value["runtime_status"], "suspended");
        for key in [
            "rpm",
            "max_rpm",
            "edge_c",
            "junction_c",
            "power_w",
            "busy_percent",
        ] {
            assert!(value[key].is_null(), "{key} must be unknown, not zero");
        }
        let hot = Gpu {
            pci: "other".into(),
            sample: Some(hot_sample()),
        };
        assert_eq!(request(&[sleeping, hot]), 100);
        let hot = Gpu {
            pci: "other".into(),
            sample: Some(hot_sample()),
        };
        assert_eq!(
            protection(&[Gpu::read_at(&root, "test").unwrap(), hot]),
            100
        );
        // Waking without working telemetry is a fault; sleep cannot mask it.
        fs::write(device.join("power/runtime_status"), "active").unwrap();
        assert!(Gpu::read_at(&root, "test").is_err());
        for (key, value) in [
            ("fan1_input", "0"),
            ("fan1_max", "3200"),
            ("temp1_label", "edge"),
            ("temp2_label", "junction"),
            ("temp1_input", "85000"),
            ("temp2_input", "100000"),
        ] {
            fs::write(p.join(key), value).unwrap();
        }
        let awake = Gpu::read_at(&root, "test").unwrap();
        assert_eq!(awake.json()["runtime_status"], "active");
        assert_eq!(awake.protection(), 100);
        // Unknown/missing power state and a missing hwmon remain failures,
        // including when a stale power file still says suspended.
        for state in ["unsupported", "invalid"] {
            fs::write(device.join("power/runtime_status"), state).unwrap();
            assert!(Gpu::read_at(&root, "test").is_err());
        }
        fs::remove_file(device.join("power/runtime_status")).unwrap();
        assert!(Gpu::read_at(&root, "test").is_err());
        fs::write(device.join("power/runtime_status"), "suspended").unwrap();
        fs::remove_file(p.join("name")).unwrap();
        assert!(Gpu::read_at(&root, "test").is_err());
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn suspend_racing_with_busy_read_is_recognized_but_active_busy_is_a_fault() {
        let sleeping = Gpu::sample(
            "test",
            || Ok(RuntimeState::Suspended),
            || panic!("must not read or wake a suspended GPU"),
        )
        .unwrap();
        assert!(sleeping.sample.is_none());
        let mut states = [RuntimeState::Active, RuntimeState::Suspended].into_iter();
        let sleeping = Gpu::sample(
            "test",
            || Ok(states.next().unwrap()),
            || Err(std::io::Error::from_raw_os_error(libc::EBUSY).into()),
        )
        .unwrap();
        assert_eq!(sleeping.json()["runtime_status"], "suspended");
        let err = Gpu::sample(
            "test",
            || Ok(RuntimeState::Active),
            || Err(std::io::Error::from_raw_os_error(libc::EBUSY).into()),
        )
        .err()
        .unwrap();
        assert_eq!(
            err.downcast_ref::<std::io::Error>().unwrap().raw_os_error(),
            Some(libc::EBUSY)
        );
    }
    #[test]
    fn resume_retries_then_uses_live_temperature_protection() {
        let mut states = [
            RuntimeState::Transitioning,
            RuntimeState::Active,
            RuntimeState::Active,
        ]
        .into_iter();
        let awake =
            Gpu::sample("test", || Ok(states.next().unwrap()), || Ok(hot_sample())).unwrap();
        assert_eq!(awake.protection(), 100);
        assert_eq!(awake.json()["runtime_status"], "active");
        let mut states = [
            RuntimeState::Active,
            RuntimeState::Transitioning,
            RuntimeState::Active,
            RuntimeState::Active,
        ]
        .into_iter();
        let mut reads = 0;
        let awake = Gpu::sample(
            "test",
            || Ok(states.next().unwrap()),
            || {
                reads += 1;
                if reads == 1 {
                    Err(std::io::Error::from_raw_os_error(libc::EBUSY).into())
                } else {
                    Ok(hot_sample())
                }
            },
        )
        .unwrap();
        assert_eq!(reads, 2);
        assert_eq!(awake.protection(), 100);
        assert!(
            Gpu::sample(
                "test",
                || Ok(RuntimeState::Transitioning),
                || panic!("must not read while transitioning")
            )
            .is_err()
        );
    }
    #[test]
    fn stopped_fan_is_valid_but_missing_and_invalid_telemetry_fail() {
        let root = std::env::temp_dir().join(format!("fan-feedback-gpu-{}", std::process::id()));
        let p = root.join("test/hwmon/hwmon9");
        fs::create_dir_all(&p).unwrap();
        fs::create_dir_all(root.join("test/power")).unwrap();
        fs::write(root.join("test/power/runtime_status"), "active").unwrap();
        for (key, value) in [
            ("name", "amdgpu"),
            ("fan1_input", "0"),
            ("fan1_max", "3200"),
            ("temp1_label", "edge"),
            ("temp2_label", "junction"),
            ("temp1_input", "49000"),
            ("temp2_input", "57000"),
        ] {
            fs::write(p.join(key), value).unwrap();
        }
        let g = Gpu::read_at(&root, "test").unwrap();
        assert_eq!(g.request(), 30);
        assert_eq!(g.protection(), 0);
        fs::write(p.join("fan1_input"), "1600").unwrap();
        assert_eq!(Gpu::read_at(&root, "test").unwrap().request(), 55);
        fs::write(p.join("temp2_input"), "100000").unwrap();
        assert_eq!(Gpu::read_at(&root, "test").unwrap().protection(), 100);
        fs::write(p.join("fan1_max"), "0").unwrap();
        assert!(Gpu::read_at(&root, "test").is_err());
        fs::write(p.join("fan1_max"), "3200").unwrap();
        fs::remove_file(p.join("temp1_input")).unwrap();
        assert!(Gpu::read_at(&root, "test").is_err());
        fs::remove_dir_all(root).unwrap();
    }
}
