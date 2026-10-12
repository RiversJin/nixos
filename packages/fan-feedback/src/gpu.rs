use crate::{Result, control::interpolate};
use serde_json::{Value, json};
use std::{fs, path::Path};

pub struct Gpu {
    pub pci: String,
    pub rpm: u32,
    pub max_rpm: u32,
    pub edge_c: f64,
    pub junction_c: f64,
    pub request: u8,
    pub protection: u8,
    busy: Option<u8>,
    power_w: Option<f64>,
}
fn number(path: &Path) -> Result<f64> {
    let n = fs::read_to_string(path)?.trim().parse::<f64>()?;
    if !n.is_finite() {
        return Err("non-finite GPU telemetry".into());
    }
    Ok(n)
}
impl Gpu {
    fn read_at(root: &Path, pci: &str) -> Result<Self> {
        let device = root.join(pci);
        for entry in fs::read_dir(device.join("hwmon"))? {
            let p = entry?.path();
            if !fs::read_to_string(p.join("name")).is_ok_and(|s| s.trim() == "amdgpu") {
                continue;
            }
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
            return Ok(Self {
                pci: pci.into(),
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
            });
        }
        Err(format!("{pci}: amdgpu hwmon unavailable").into())
    }
    pub fn json(&self) -> Value {
        json!({"pci":self.pci,"rpm":self.rpm,"max_rpm":self.max_rpm,"edge_c":self.edge_c,
            "junction_c":self.junction_c,"request_pwm":self.request,"protection_pwm":self.protection,
            "busy_percent":self.busy,"power_w":self.power_w})
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
    gpus.iter().map(|g| g.request).max().unwrap_or(30)
}
pub fn protection(gpus: &[Gpu]) -> u8 {
    gpus.iter().map(|g| g.protection).max().unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn stopped_fan_is_valid_but_missing_and_invalid_telemetry_fail() {
        let root = std::env::temp_dir().join(format!("fan-feedback-gpu-{}", std::process::id()));
        let p = root.join("test/hwmon/hwmon9");
        fs::create_dir_all(&p).unwrap();
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
        assert_eq!(g.request, 30);
        assert_eq!(g.protection, 0);
        fs::write(p.join("fan1_input"), "1600").unwrap();
        assert_eq!(Gpu::read_at(&root, "test").unwrap().request, 55);
        fs::write(p.join("temp2_input"), "100000").unwrap();
        assert_eq!(Gpu::read_at(&root, "test").unwrap().protection, 100);
        fs::write(p.join("fan1_max"), "0").unwrap();
        assert!(Gpu::read_at(&root, "test").is_err());
        fs::write(p.join("fan1_max"), "3200").unwrap();
        fs::remove_file(p.join("temp1_input")).unwrap();
        assert!(Gpu::read_at(&root, "test").is_err());
        fs::remove_dir_all(root).unwrap();
    }
}
