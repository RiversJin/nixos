use crate::{Config, Result, STOP, atomic_json, control::interpolate, lock_at, timestamp};
use serde_json::{Value, json};
use std::{
    fs,
    path::{Path, PathBuf},
    sync::atomic::Ordering,
    thread,
    time::{Duration, Instant},
};

const BOARD_NAME: &str = "ROG STRIX B850-A GAMING WIFI7 S NEO";
const HWMON_ROOT: &str = "/sys/devices/platform/nct6775.656/hwmon";
const HWMON_NAME: &str = "nct6799";
const CASE_CHANNEL: u8 = 1;
const EXPECTED_DIMMS: usize = 2;

pub struct Settings {
    pub state: PathBuf,
    pub minimum: u8,
    pub channel: u8,
}
impl Default for Settings {
    fn default() -> Self {
        Self {
            state: "/run/host-fan-feedback".into(),
            minimum: 20,
            channel: CASE_CHANNEL,
        }
    }
}
fn board_path() -> Result<PathBuf> {
    if fs::read_to_string("/sys/class/dmi/id/board_vendor")?.trim() != "ASUSTeK COMPUTER INC."
        || fs::read_to_string("/sys/class/dmi/id/board_name")?.trim() != BOARD_NAME
    {
        return Err("host fan mapping is not verified for this motherboard".into());
    }
    for e in fs::read_dir(HWMON_ROOT)? {
        let p = e?.path();
        if fs::read_to_string(p.join("name")).is_ok_and(|s| s.trim() == HWMON_NAME) {
            return Ok(p);
        }
    }
    Err("ASUS NCT6701D compatible hwmon unavailable".into())
}

pub fn valid_channel(channel: u8) -> bool {
    channel == CASE_CHANNEL
}

fn automatic(mode: u32) -> bool {
    matches!(mode, 2 | 3 | 5)
}

fn manual(mode: u32, pwm: u32) -> bool {
    // nct6775 reports manual 255/255 as mode 0 (full speed).
    mode == 1 || (mode == 0 && pwm == 255)
}
fn number(p: &Path) -> Result<u32> {
    Ok(fs::read_to_string(p)?.trim().parse()?)
}
fn temp(p: &Path) -> Result<f64> {
    let t = fs::read_to_string(p)?.trim().parse::<f64>()? / 1000.;
    if !t.is_finite() || !(0. ..125.).contains(&t) {
        return Err(format!("invalid temperature at {}", p.display()).into());
    }
    Ok(t)
}
fn cpu_temp() -> Result<f64> {
    for e in fs::read_dir("/sys/class/hwmon")? {
        let p = e?.path();
        if fs::read_to_string(p.join("name")).is_ok_and(|s| s.trim() == "k10temp")
            && fs::read_to_string(p.join("temp1_label")).is_ok_and(|s| s.trim() == "Tctl")
        {
            return temp(&p.join("temp1_input"));
        }
    }
    Err("CPU Tctl sensor unavailable".into())
}

fn memory_temps(root: &Path) -> Result<(f64, Vec<Value>)> {
    let mut sensors = Vec::new();
    let mut hottest = 0.0_f64;
    for e in fs::read_dir(root)? {
        let p = e?.path();
        if !fs::read_to_string(p.join("name")).is_ok_and(|s| s.trim() == "spd5118") {
            continue;
        }
        if number(&p.join("temp1_enable"))? != 1 {
            return Err("DDR5 temperature sensor disabled".into());
        }
        let value = temp(&p.join("temp1_input"))?;
        hottest = hottest.max(value);
        sensors.push(json!({"hwmon":p,"label":"DDR5 SPD","c":value}));
    }
    if sensors.len() != EXPECTED_DIMMS {
        return Err(format!(
            "expected {EXPECTED_DIMMS} DDR5 temperature sensors, found {}",
            sensors.len()
        )
        .into());
    }
    sensors.sort_by_key(|s| s["hwmon"].as_str().unwrap_or_default().to_owned());
    Ok((hottest, sensors))
}

struct Readings {
    cpu: f64,
    memory: f64,
    sensors: Vec<Value>,
    raw: u8,
    rpm: u32,
    mode: u8,
}
fn read_at(p: &Path, channel: u8, cpu: f64, memory: f64, sensors: Vec<Value>) -> Result<Readings> {
    if !valid_channel(channel)
        || !cpu.is_finite()
        || !(0.0..125.0).contains(&cpu)
        || !memory.is_finite()
        || !(0.0..125.0).contains(&memory)
    {
        return Err("invalid host channel or temperature".into());
    }
    let raw = number(&p.join(format!("pwm{channel}")))?;
    let rpm = number(&p.join(format!("fan{channel}_input")))?;
    let mode = number(&p.join(format!("pwm{channel}_enable")))?;
    if raw > 255 || rpm > 20000 || !(manual(mode, raw) || automatic(mode)) {
        return Err("invalid host fan telemetry".into());
    }
    Ok(Readings {
        cpu,
        memory,
        sensors,
        raw: raw as u8,
        rpm,
        mode: mode as u8,
    })
}
fn readings(s: &Settings) -> Result<Readings> {
    let (memory, sensors) = memory_temps(Path::new("/sys/class/hwmon"))?;
    read_at(&board_path()?, s.channel, cpu_temp()?, memory, sensors)
}
fn percent(raw: u8) -> u8 {
    ((u32::from(raw) * 100 + 127) / 255) as u8
}
fn raw(percent: u8) -> u8 {
    ((u32::from(percent) * 255 + 50) / 100) as u8
}

struct Fan {
    path: PathBuf,
    state: PathBuf,
    channel: u8,
    automatic_mode: u32,
}
impl Fan {
    fn open(s: &Settings) -> Result<Self> {
        Self::open_at(board_path()?, s)
    }
    fn open_at(p: PathBuf, s: &Settings) -> Result<Self> {
        if !valid_channel(s.channel) {
            return Err("unverified host fan channel".into());
        }
        let automatic_mode = number(&p.join(format!("pwm{}_enable", s.channel)))?;
        if !automatic(automatic_mode) {
            return Err("host fan is not automatically controlled; refusing takeover".into());
        }
        let initial_pwm = number(&p.join(format!("pwm{}", s.channel)))?;
        if initial_pwm > 255 {
            return Err("invalid host PWM before takeover".into());
        }
        if number(&p.join(format!("fan{}_input", s.channel)))? < 300 {
            return Err("host fan is not spinning before takeover".into());
        }
        if s.state.join("owned").try_exists()? {
            return Err("host ownership must be restored before takeover".into());
        }
        // Persist the exact automatic mode before changing hardware. ASUS uses
        // Smart Fan IV (5); writing the old MSI mode 2 would change its policy.
        atomic_json(
            &s.state.join("owned"),
            &json!({
                "version":1,"board":BOARD_NAME,"hwmon":HWMON_NAME,
                "channel":s.channel,"automatic_mode":automatic_mode
            }),
        )?;
        let fan = Self {
            path: p,
            state: s.state.clone(),
            channel: s.channel,
            automatic_mode,
        };
        fs::write(fan.path.join(format!("pwm{}_enable", s.channel)), "1\n")?;
        // Switching out of Smart Fan IV revives the chip's last manual PWM
        // command, which may be 255 from an earlier test or protection event.
        // Seed manual control from the current automatic output immediately.
        fs::write(
            fan.path.join(format!("pwm{}", s.channel)),
            format!("{initial_pwm}\n"),
        )?;
        if !manual(
            number(&fan.path.join(format!("pwm{}_enable", s.channel)))?,
            number(&fan.path.join(format!("pwm{}", s.channel)))?,
        ) || number(&fan.path.join(format!("pwm{}", s.channel)))? != initial_pwm
        {
            return Err("host manual mode not confirmed".into());
        }
        Ok(fan)
    }
    fn set(&self, pwm: u8) -> Result<()> {
        if pwm > 100 {
            return Err("invalid host PWM".into());
        }
        let path = self.path.join(format!("pwm{}", self.channel));
        fs::write(&path, format!("{}\n", raw(pwm)))?;
        let until = Instant::now() + Duration::from_secs(5);
        loop {
            if number(&path)? == u32::from(raw(pwm))
                && manual(
                    number(&self.path.join(format!("pwm{}_enable", self.channel)))?,
                    u32::from(raw(pwm)),
                )
            {
                return Ok(());
            }
            if Instant::now() >= until {
                return Err("host PWM not confirmed".into());
            }
            thread::sleep(Duration::from_millis(100));
        }
    }
}
impl Drop for Fan {
    fn drop(&mut self) {
        let s = Settings {
            state: self.state.clone(),
            channel: self.channel,
            minimum: 35,
        };
        if let Err(e) = restore_at(&self.path, &s) {
            eprintln!("Host BIOS restoration failed: {e}");
        }
    }
}
pub fn restore(s: &Settings) -> Result<()> {
    if !s.state.join("owned").try_exists()? {
        return Ok(());
    }
    restore_at(&board_path()?, s)
}

fn restore_at(hwmon: &Path, s: &Settings) -> Result<()> {
    let marker = s.state.join("owned");
    let saved: Value = match fs::read_to_string(&marker) {
        Ok(v) => serde_json::from_str(&v)?,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(e.into()),
    };
    let mode = saved["automatic_mode"]
        .as_u64()
        .ok_or("missing original automatic mode")?;
    if saved["version"] != 1
        || saved["board"] != BOARD_NAME
        || saved["hwmon"] != HWMON_NAME
        || !valid_channel(s.channel)
        || saved["channel"] != s.channel
        || !matches!(mode, 2 | 3 | 5)
    {
        return Err("invalid host ownership marker".into());
    }
    let p = hwmon.join(format!("pwm{}_enable", s.channel));
    fs::write(&p, format!("{mode}\n"))?;
    if u64::from(number(&p)?) != mode {
        return Err("host BIOS mode not confirmed".into());
    }
    fs::remove_file(marker)?;
    atomic_json(
        &s.state.join("status.json"),
        &json!({
            "time":timestamp(),"policy":"restored-bios","bios_confirmed":true,
            "channel":s.channel,"automatic_mode":mode,"manual":false
        }),
    )?;
    eprintln!(
        "Host fan {} returned to BIOS automatic mode {mode}",
        s.channel
    );
    Ok(())
}

const CPU_FILTER_SECONDS: f64 = 60.;
const MEMORY_FILTER_SECONDS: f64 = 15.;

struct Policy {
    minimum: u8,
    cpu: Option<f64>,
    memory: f64,
    sample_at: u64,
    held: u8,
    hold_until: u64,
    last_change: u64,
    request: u8,
    cpu_request: u8,
    memory_request: u8,
}
impl Policy {
    fn new(minimum: u8) -> Self {
        Self {
            minimum,
            cpu: None,
            memory: 0.,
            sample_at: 0,
            held: minimum,
            hold_until: 0,
            last_change: 0,
            request: minimum,
            cpu_request: minimum,
            memory_request: minimum,
        }
    }
    fn decide(&mut self, now: u64, cpu: f64, memory: f64, quiet: bool, current: u8) -> u8 {
        let floor = if quiet {
            self.minimum
        } else {
            self.minimum.max(45)
        };
        if let Some(old) = self.cpu {
            let elapsed = now.saturating_sub(self.sample_at) as f64;
            let cpu_alpha = 1. - (-elapsed / CPU_FILTER_SECONDS).exp();
            let memory_alpha = 1. - (-elapsed / MEMORY_FILTER_SECONDS).exp();
            self.cpu = Some(old + (cpu - old) * cpu_alpha);
            self.memory += (memory - self.memory) * memory_alpha;
        } else {
            self.cpu = Some(cpu);
            self.memory = memory;
        }
        self.sample_at = now;
        self.cpu_request = interpolate(
            self.cpu.unwrap(),
            &[
                (45., floor),
                (55., floor.max(45)),
                (65., 60),
                (75., 75),
                (80., 85),
                (85., 100),
            ],
        );
        self.memory_request = interpolate(
            self.memory,
            &[
                (40., floor),
                (45., floor.max(45)),
                (50., 60),
                (55., 75),
                (60., 85),
                (65., 100),
            ],
        );
        self.request = self.cpu_request.max(self.memory_request);
        if self.request >= self.held || now >= self.hold_until {
            self.held = self.request;
            self.hold_until = now + 120;
        }
        if cpu >= 85. || memory >= 65. {
            return 100;
        }
        if cpu >= 80. || memory >= 60. {
            return self.held.max(85).max(current);
        }
        let target = self.held.max(floor);
        if target >= current.saturating_add(3) || current < floor {
            // CPU junction jumps are handled by its own BIOS fan. Raise case
            // airflow gently unless the DIMMs request the held target.
            let (interval, step) = if self.memory_request >= target {
                (15, 5)
            } else {
                (30, 3)
            };
            if now.saturating_sub(self.last_change) >= interval {
                return target.min(current.saturating_add(step)).max(floor);
            }
        } else if (target.saturating_add(3) < current || (target == floor && target < current))
            && now.saturating_sub(self.last_change) >= 60
        {
            return target.max(current.saturating_sub(2));
        }
        current.max(floor)
    }
}

pub fn status(s: &Settings) -> Result<Value> {
    let mut v: Value = serde_json::from_str(&fs::read_to_string(s.state.join("status.json"))?)?;
    let age = timestamp() - v["time"].as_f64().ok_or("missing host status timestamp")?;
    v["age_seconds"] = json!(age.round());
    Ok(v)
}
pub fn daemon(c: &Config) -> Result<()> {
    let _lock = lock_at(&c.host.state)?;
    // Recover only our own outstanding takeover, never an unrelated manual fan.
    restore(&c.host)?;
    let result = (|| -> Result<()> {
        let _initial = readings(&c.host)?;
        let fan = Fan::open(&c.host)?;
        let mut policy = Policy::new(c.host.minimum);
        let start = Instant::now();
        let mut next = Instant::now();
        let mut heartbeat = Instant::now();
        let mut stalled = 0;
        while !STOP.load(Ordering::Relaxed) {
            if Instant::now() < next {
                thread::sleep(Duration::from_millis(250));
                continue;
            }
            next = Instant::now() + Duration::from_secs(5);
            let mut r = readings(&c.host)?;
            if !manual(u32::from(r.mode), u32::from(r.raw)) {
                return Err("host fan mode changed externally".into());
            }
            if r.rpm < 300 {
                stalled += 1;
            } else {
                stalled = 0;
            }
            if stalled >= 3 {
                return Err("host fan RPM remained below 300".into());
            }
            let (quiet, reason) = c.quiet();
            let now = start.elapsed().as_secs();
            let target = policy.decide(now, r.cpu, r.memory, quiet, percent(r.raw));
            if raw(target) != r.raw {
                fan.set(target)?;
                policy.last_change = now;
                r = readings(&c.host)?;
                eprintln!(
                    "Host {reason}: CPU={:.1} C, memory={:.1} C, PWM={target}%, RPM={}",
                    r.cpu, r.memory, r.rpm
                );
            }
            let v = json!({"time":timestamp(),"policy":reason,"cpu_c":r.cpu,"memory_c":r.memory,
                "filtered_cpu_c":policy.cpu,"filtered_memory_c":policy.memory,"memory_sensors":r.sensors,
                "requested_pwm":policy.request,"cpu_request_pwm":policy.cpu_request,"memory_request_pwm":policy.memory_request,
                "cpu_filter_seconds":CPU_FILTER_SECONDS,"memory_filter_seconds":MEMORY_FILTER_SECONDS,"held_pwm":policy.held,"pwm":percent(r.raw),"pwm_raw":r.raw,
                "rpm":r.rpm,"manual":manual(u32::from(r.mode),u32::from(r.raw)),"pwm_enable":r.mode,
                "automatic_mode":fan.automatic_mode,"channel":c.host.channel,"cpu_fan_control":"BIOS"});
            atomic_json(&c.host.state.join("status.json"), &v)?;
            if heartbeat.elapsed() >= Duration::from_secs(60) {
                eprintln!("{v}");
                heartbeat = Instant::now();
            }
        }
        drop(fan);
        Ok(())
    })();
    let fallback = restore(&c.host);
    let value = json!({"time":timestamp(),"policy":if result.is_ok(){"stopped-bios"}else{"fault-bios"},
        "error":result.as_ref().err().map(ToString::to_string),"bios_confirmed":fallback.is_ok() && board_path().and_then(|p| number(&p.join(format!("pwm{}_enable",c.host.channel)))).is_ok_and(automatic)});
    atomic_json(&c.host.state.join("status.json"), &value)?;
    fallback?;
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn independent_host_curves_and_immediate_protection() {
        let mut p = Policy::new(20);
        assert_eq!(p.decide(0, 38., 39., true, 20), 20);
        assert_eq!(p.request, 20);
        assert_eq!(p.decide(1, 85., 39., true, 35), 100);
        assert_eq!(p.decide(2, 40., 65., true, 35), 100);
        assert!(p.decide(3, 80., 39., true, 35) >= 85);
        assert_eq!(Policy::new(20).decide(0, 38., 39., false, 20), 45);
    }
    #[test]
    fn heat_persists_after_load_then_releases_slowly() {
        let mut p = Policy::new(20);
        p.decide(0, 75., 55., true, 75);
        assert_eq!(p.held, 75);
        p.decide(10, 38., 39., true, 75);
        assert_eq!(p.held, 75);
        let next = p.decide(121, 38., 39., true, 75);
        assert_eq!(next, 73);
        assert_eq!(p.held, 20);
    }
    #[test]
    fn short_cpu_burst_does_not_raise_case_fan() {
        let mut p = Policy::new(20);
        assert_eq!(p.decide(0, 38., 39., true, 20), 20);
        // A ten-second junction spike used to be amplified by the 15-second
        // filter and then held for two minutes. The DIMMs remain cool.
        for now in (5..=120).step_by(5) {
            let cpu = if now <= 10 { 75. } else { 38. };
            assert_eq!(p.decide(now, cpu, 39., true, 20), 20);
        }
    }
    #[test]
    fn sustained_cpu_load_ramps_gently_but_memory_ramps_faster() {
        let mut p = Policy::new(20);
        p.decide(0, 38., 39., true, 20);
        let mut current = 20;
        let mut changes = Vec::new();
        for now in (5..=150).step_by(5) {
            let next = p.decide(now, 75., 39., true, current);
            if next != current {
                assert!(next > current && next - current <= 3);
                assert!(now - p.last_change >= 30);
                p.last_change = now;
                current = next;
                changes.push(now);
            }
        }
        assert!(changes.len() >= 4 && current > 20);
        assert!(p.cpu_request >= 65);
        let mut memory = Policy::new(20);
        memory.decide(0, 38., 50., true, 20);
        assert_eq!(memory.decide(15, 38., 50., true, 20), 25);
        // Raw guards override both the slow filter and the rise limiter.
        p.last_change = 150;
        assert_eq!(p.decide(151, 85., 39., true, current), 100);
        assert!(p.decide(152, 80., 39., true, current) >= 85);
        assert_eq!(p.decide(153, 38., 65., true, current), 100);
    }
    #[test]
    fn ddr5_sensor_loss_and_disabled_or_invalid_readings_are_faults() {
        let root = test_root("memory");
        fs::create_dir_all(&root).unwrap();
        for (n, value) in [(3, "39000"), (4, "42000")] {
            let p = root.join(format!("hwmon{n}"));
            fs::create_dir_all(&p).unwrap();
            fs::write(p.join("name"), "spd5118\n").unwrap();
            fs::write(p.join("temp1_enable"), "1").unwrap();
            fs::write(p.join("temp1_input"), value).unwrap();
        }
        assert_eq!(memory_temps(&root).unwrap().0, 42.);
        fs::write(root.join("hwmon3/temp1_enable"), "0").unwrap();
        assert!(memory_temps(&root).is_err());
        fs::write(root.join("hwmon3/temp1_enable"), "1").unwrap();
        fs::write(root.join("hwmon3/temp1_input"), "NaN").unwrap();
        assert!(memory_temps(&root).is_err());
        fs::remove_dir_all(root.join("hwmon3")).unwrap();
        assert!(memory_temps(&root).is_err());
        fs::remove_dir_all(root).unwrap();
    }

    fn test_root(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!("fan-feedback-host-{name}-{}", std::process::id()))
    }

    fn fixture(name: &str) -> (PathBuf, Settings) {
        let root = test_root(name);
        let p = root.join("hwmon");
        let state = root.join("state");
        fs::create_dir_all(&p).unwrap();
        fs::create_dir_all(&state).unwrap();
        for (key, value) in [
            ("pwm1", "76"),
            ("fan1_input", "900"),
            ("pwm1_enable", "5"),
            ("pwm2", "76"),
            ("pwm2_enable", "5"),
        ] {
            fs::write(p.join(key), value).unwrap();
        }
        (
            p,
            Settings {
                state,
                ..Settings::default()
            },
        )
    }

    #[test]
    fn full_speed_mode_zero_is_manual_but_bad_telemetry_is_rejected() {
        let (p, s) = fixture("telemetry");
        assert_eq!(read_at(&p, 1, 38., 39., vec![]).unwrap().mode, 5);
        assert!(read_at(&p, 2, 38., 39., vec![]).is_err());
        assert!(read_at(&p, 1, f64::NAN, 39., vec![]).is_err());
        fs::write(p.join("pwm1_enable"), "0").unwrap();
        assert!(read_at(&p, 1, 38., 39., vec![]).is_err());
        fs::write(p.join("pwm1"), "255").unwrap();
        let r = read_at(&p, 1, 38., 39., vec![]).unwrap();
        assert!(manual(u32::from(r.mode), u32::from(r.raw)));
        fs::remove_file(p.join("pwm1_enable")).unwrap();
        assert!(read_at(&p, 1, 38., 39., vec![]).is_err());
        fs::remove_dir_all(s.state.parent().unwrap()).unwrap();
    }

    #[test]
    fn normal_exit_and_crash_recovery_restore_exact_automatic_mode() {
        let (p, s) = fixture("restore");
        for original in [5, 2] {
            fs::write(p.join("pwm1_enable"), format!("{original}")).unwrap();
            let fan = Fan::open_at(p.clone(), &s).unwrap();
            assert_eq!(number(&p.join("pwm1_enable")).unwrap(), 1);
            if original == 5 {
                assert_eq!(number(&p.join("pwm1")).unwrap(), 76);
            }
            fan.set(100).unwrap();
            fs::write(p.join("pwm1_enable"), "0").unwrap();
            fan.set(100).unwrap();
            drop(fan);
            assert_eq!(number(&p.join("pwm1_enable")).unwrap(), original);
            assert!(!s.state.join("owned").exists());
            let fan = Fan::open_at(p.clone(), &s).unwrap();
            std::mem::forget(fan); // Simulate process death before Drop.
            assert!(s.state.join("owned").exists());
            restore_at(&p, &s).unwrap();
            assert_eq!(number(&p.join("pwm1_enable")).unwrap(), original);
            let status: Value =
                serde_json::from_str(&fs::read_to_string(s.state.join("status.json")).unwrap())
                    .unwrap();
            assert_eq!(status["policy"], "restored-bios");
            assert_eq!(status["automatic_mode"], original);
            assert_eq!(status["manual"], false);
            assert_eq!(number(&p.join("pwm2_enable")).unwrap(), 5);
            assert_eq!(number(&p.join("pwm2")).unwrap(), 76);
        }
        fs::remove_dir_all(s.state.parent().unwrap()).unwrap();
    }

    #[test]
    fn refuse_unowned_manual_fans_and_foreign_ownership_markers() {
        let (p, s) = fixture("ownership");
        fs::write(p.join("pwm1_enable"), "1").unwrap();
        assert!(Fan::open_at(p.clone(), &s).is_err());
        assert!(!s.state.join("owned").exists());
        restore_at(&p, &s).unwrap();
        assert_eq!(number(&p.join("pwm1_enable")).unwrap(), 1);
        for marker in [
            json!(3),
            json!({"version":1,"board":BOARD_NAME,
            "hwmon":HWMON_NAME,"channel":2,"automatic_mode":5}),
            json!({"version":1,"board":"old MSI board", "hwmon":HWMON_NAME,
                "channel":1,"automatic_mode":5}),
        ] {
            atomic_json(&s.state.join("owned"), &marker).unwrap();
            assert!(restore_at(&p, &s).is_err());
            assert_eq!(number(&p.join("pwm1_enable")).unwrap(), 1);
            assert_eq!(number(&p.join("pwm2_enable")).unwrap(), 5);
        }
        fs::remove_dir_all(s.state.parent().unwrap()).unwrap();
    }
}
