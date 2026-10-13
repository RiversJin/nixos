use crate::{Config, Result, STOP, atomic_json, control::interpolate, lock_at, timestamp};
use serde_json::{Value, json};
use std::{
    fs,
    path::{Path, PathBuf},
    sync::atomic::Ordering,
    thread,
    time::{Duration, Instant},
};

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
            channel: 3,
        }
    }
}
fn board_path() -> Result<PathBuf> {
    for e in fs::read_dir("/sys/devices/platform/nct6683.2592/hwmon")? {
        let p = e?.path();
        if fs::read_to_string(p.join("name")).is_ok_and(|s| s.trim() == "nct6687") {
            return Ok(p);
        }
    }
    Err("MSI board hwmon unavailable".into())
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
struct Readings {
    cpu: f64,
    board: f64,
    sensors: Vec<Value>,
    raw: u8,
    rpm: u32,
    mode: u8,
}
fn read_at(p: &Path, channel: u8, cpu: f64) -> Result<Readings> {
    let mut sensors = Vec::new();
    let mut board = 0.0_f64;
    // Generic firmware labels cannot identify a DIMM temperature. Use all six
    // enabled analog board channels as a conservative board hot-area proxy.
    for n in 2..=7 {
        let value = temp(&p.join(format!("temp{n}_input")))?;
        let label = fs::read_to_string(p.join(format!("temp{n}_label")))?;
        board = board.max(value);
        sensors.push(json!({"channel":n,"label":label.trim(),"c":value}));
    }
    let raw = number(&p.join(format!("pwm{channel}")))?;
    let rpm = number(&p.join(format!("fan{channel}_input")))?;
    let mode = number(&p.join(format!("pwm{channel}_enable")))?;
    if raw > 255 || rpm > 20000 || !(1..=2).contains(&mode) {
        return Err("invalid host fan telemetry".into());
    }
    Ok(Readings {
        cpu,
        board,
        sensors,
        raw: raw as u8,
        rpm,
        mode: mode as u8,
    })
}
fn readings(s: &Settings) -> Result<Readings> {
    read_at(&board_path()?, s.channel, cpu_temp()?)
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
}
impl Fan {
    fn open(s: &Settings) -> Result<Self> {
        let p = board_path()?;
        if number(&p.join(format!("pwm{}_enable", s.channel)))? != 2 {
            return Err("host fan is already manually controlled; refusing takeover".into());
        }
        let fan = Self {
            path: p,
            state: s.state.clone(),
            channel: s.channel,
        };
        // The marker is written before takeover so ExecStopPost also covers a
        // crash in the small interval between the mode write and its readback.
        fs::write(fan.state.join("owned"), format!("{}\n", s.channel))?;
        fs::write(fan.path.join(format!("pwm{}_enable", s.channel)), "1\n")?;
        if number(&fan.path.join(format!("pwm{}_enable", s.channel)))? != 1 {
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
                && number(&self.path.join(format!("pwm{}_enable", self.channel)))? == 1
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
        if let Err(e) = restore(&s) {
            eprintln!("Host BIOS restoration failed: {e}");
        }
    }
}
pub fn restore(s: &Settings) -> Result<()> {
    let marker = s.state.join("owned");
    let channel = match fs::read_to_string(&marker) {
        Ok(v) => v.trim().parse::<u8>()?,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(e.into()),
    };
    if !(3..=5).contains(&channel) {
        return Err("invalid host ownership marker".into());
    }
    let p = board_path()?.join(format!("pwm{channel}_enable"));
    fs::write(&p, "2\n")?;
    if number(&p)? != 2 {
        return Err("host BIOS mode not confirmed".into());
    }
    fs::remove_file(marker)?;
    eprintln!("Host fan {channel} returned to BIOS automatic control");
    Ok(())
}

const CPU_FILTER_SECONDS: f64 = 60.;
const BOARD_FILTER_SECONDS: f64 = 15.;

struct Policy {
    minimum: u8,
    cpu: Option<f64>,
    board: f64,
    sample_at: u64,
    held: u8,
    hold_until: u64,
    last_change: u64,
    request: u8,
    cpu_request: u8,
    board_request: u8,
}
impl Policy {
    fn new(minimum: u8) -> Self {
        Self {
            minimum,
            cpu: None,
            board: 0.,
            sample_at: 0,
            held: minimum,
            hold_until: 0,
            last_change: 0,
            request: minimum,
            cpu_request: minimum,
            board_request: minimum,
        }
    }
    fn decide(&mut self, now: u64, cpu: f64, board: f64, quiet: bool, current: u8) -> u8 {
        let floor = if quiet {
            self.minimum
        } else {
            self.minimum.max(45)
        };
        if let Some(old) = self.cpu {
            let elapsed = now.saturating_sub(self.sample_at) as f64;
            let cpu_alpha = 1. - (-elapsed / CPU_FILTER_SECONDS).exp();
            let board_alpha = 1. - (-elapsed / BOARD_FILTER_SECONDS).exp();
            self.cpu = Some(old + (cpu - old) * cpu_alpha);
            self.board += (board - self.board) * board_alpha;
        } else {
            self.cpu = Some(cpu);
            self.board = board;
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
        self.board_request = interpolate(
            self.board,
            &[
                (40., floor),
                (45., floor.max(45)),
                (50., 60),
                (55., 75),
                (60., 85),
                (65., 100),
            ],
        );
        self.request = self.cpu_request.max(self.board_request);
        if self.request >= self.held || now >= self.hold_until {
            self.held = self.request;
            self.hold_until = now + 120;
        }
        if cpu >= 85. || board >= 65. {
            return 100;
        }
        if cpu >= 80. || board >= 60. {
            return self.held.max(85).max(current);
        }
        let target = self.held.max(floor);
        if target >= current.saturating_add(3) || current < floor {
            // CPU junction jumps are handled by its own BIOS fan. Raise case
            // airflow gently unless the board itself requests the held target.
            let (interval, step) = if self.board_request >= target {
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
            if r.mode != 1 {
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
            let target = policy.decide(now, r.cpu, r.board, quiet, percent(r.raw));
            if raw(target) != r.raw {
                fan.set(target)?;
                policy.last_change = now;
                r = readings(&c.host)?;
                eprintln!(
                    "Host {reason}: CPU={:.1} C, board={:.1} C, PWM={target}%, RPM={}",
                    r.cpu, r.board, r.rpm
                );
            }
            let v = json!({"time":timestamp(),"policy":reason,"cpu_c":r.cpu,"board_c":r.board,
                "filtered_cpu_c":policy.cpu,"filtered_board_c":policy.board,"board_sensors":r.sensors,
                "requested_pwm":policy.request,"cpu_request_pwm":policy.cpu_request,"board_request_pwm":policy.board_request,
                "cpu_filter_seconds":CPU_FILTER_SECONDS,"board_filter_seconds":BOARD_FILTER_SECONDS,"held_pwm":policy.held,"pwm":percent(r.raw),"pwm_raw":r.raw,
                "rpm":r.rpm,"manual":r.mode==1,"channel":c.host.channel,"cpu_fan_control":"BIOS"});
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
        "error":result.as_ref().err().map(ToString::to_string),"bios_confirmed":fallback.is_ok() && board_path().and_then(|p| number(&p.join(format!("pwm{}_enable",c.host.channel)))).is_ok_and(|mode| mode==2)});
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
        // filter and then held for two minutes. The board remains cool.
        for now in (5..=120).step_by(5) {
            let cpu = if now <= 10 { 75. } else { 38. };
            assert_eq!(p.decide(now, cpu, 39., true, 20), 20);
        }
    }
    #[test]
    fn sustained_cpu_load_ramps_gently_but_board_ramps_faster() {
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
        let mut board = Policy::new(20);
        board.decide(0, 38., 50., true, 20);
        assert_eq!(board.decide(15, 38., 50., true, 20), 25);
        // Raw guards override both the slow filter and the rise limiter.
        p.last_change = 150;
        assert_eq!(p.decide(151, 85., 39., true, current), 100);
        assert!(p.decide(152, 80., 39., true, current) >= 85);
        assert_eq!(p.decide(153, 38., 65., true, current), 100);
    }
    #[test]
    fn cpu_and_board_faults_are_not_silently_ignored() {
        let root = std::env::temp_dir().join(format!("fan-feedback-host-{}", std::process::id()));
        fs::create_dir_all(&root).unwrap();
        for n in 2..=7 {
            fs::write(root.join(format!("temp{n}_input")), "39000").unwrap();
            fs::write(root.join(format!("temp{n}_label")), "Thermistor").unwrap();
        }
        for (key, value) in [
            ("pwm3", "118"),
            ("fan3_input", "1250"),
            ("pwm3_enable", "2"),
        ] {
            fs::write(root.join(key), value).unwrap();
        }
        assert_eq!(read_at(&root, 3, 38.).unwrap().board, 39.);
        fs::write(root.join("temp4_input"), "NaN").unwrap();
        assert!(read_at(&root, 3, 38.).is_err());
        fs::write(root.join("temp4_input"), "39000").unwrap();
        fs::remove_file(root.join("pwm3_enable")).unwrap();
        assert!(read_at(&root, 3, 38.).is_err());
        fs::remove_dir_all(root).unwrap();
    }
}
