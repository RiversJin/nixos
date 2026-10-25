mod bluez;
mod control;
mod gpu;
mod host;
mod protocol;

use bluez::Fan;
use control::Policy;
use serde_json::json;
use std::{
    error::Error,
    fs::{self, File, OpenOptions},
    io::Write,
    os::fd::AsRawFd,
    path::{Path, PathBuf},
    sync::atomic::{AtomicBool, Ordering},
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

type Result<T> = std::result::Result<T, Box<dyn Error>>;
static STOP: AtomicBool = AtomicBool::new(false);
extern "C" fn stop(_: libc::c_int) {
    STOP.store(true, Ordering::Relaxed);
}

struct Config {
    address: String,
    adapter: String,
    pci: String,
    gpu_pci: Vec<String>,
    minimum: u8,
    fallback: u8,
    presence: PathBuf,
    state: PathBuf,
    host: host::Settings,
}
impl Default for Config {
    fn default() -> Self {
        Self {
            address: "0D:B3:AF:43:2C:DB".into(),
            adapter: "hci0".into(),
            pci: "0000:16:00.0".into(),
            gpu_pci: vec!["0000:07:00.0".into(), "0000:10:00.0".into()],
            minimum: 30,
            fallback: 100,
            presence: "/run/user/1000/fan-feedback-presence".into(),
            state: "/run/fan-feedback".into(),
            host: host::Settings::default(),
        }
    }
}
impl Config {
    fn load(path: &Path) -> Result<Self> {
        let mut c = Self::default();
        for line in fs::read_to_string(path)?.lines() {
            let line = line.split('#').next().unwrap().trim();
            if line.is_empty() {
                continue;
            }
            let (k, v) = line
                .split_once('=')
                .ok_or("configuration needs key=value")?;
            let v = v.trim();
            match k.trim() {
                "address" => c.address = v.into(),
                "adapter" => c.adapter = v.into(),
                "pci" => c.pci = v.into(),
                "gpu_pci" => c.gpu_pci = v.split(',').map(|s| s.trim().to_owned()).collect(),
                "minimum_pwm" => c.minimum = v.parse()?,
                "fallback_pwm" => c.fallback = v.parse()?,
                "presence_file" => c.presence = v.into(),
                "state_dir" => c.state = v.into(),
                "host_state_dir" => c.host.state = v.into(),
                "host_minimum_pwm" => c.host.minimum = v.parse()?,
                "host_channel" => c.host.channel = v.parse()?,
                _ => return Err(format!("unknown config key {k}").into()),
            }
        }
        if !(30..=45).contains(&c.minimum) || !(80..=100).contains(&c.fallback) {
            return Err("unsafe PWM limits".into());
        }
        if !(20..=50).contains(&c.host.minimum) || !host::valid_channel(c.host.channel) {
            return Err("unsafe host fan configuration".into());
        }
        if c.address.split(':').count() != 6
            || c.address
                .split(':')
                .any(|b| b.len() != 2 || u8::from_str_radix(b, 16).is_err())
        {
            return Err("invalid Bluetooth address".into());
        }
        if c.pci.contains('/')
            || c.adapter.contains('/')
            || c.gpu_pci.is_empty()
            || c.gpu_pci
                .iter()
                .any(|p| p.is_empty() || p.contains('/') || p.contains(".."))
        {
            return Err("invalid device identifier".into());
        }
        Ok(c)
    }
    fn quiet(&self) -> (bool, String) {
        let mode = fs::read_to_string(self.state.join("mode")).unwrap_or_else(|_| "auto".into());
        match mode.trim() {
            "quiet" => (true, "quiet".into()),
            "cool" => (false, "cool".into()),
            _ => {
                let away = fs::read_to_string(&self.presence).is_ok_and(|s| s.trim() == "away");
                (
                    !away,
                    if away { "auto-away" } else { "auto-present" }.into(),
                )
            }
        }
    }
}

fn timestamp() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
}
fn temperature(c: &Config) -> Result<f64> {
    let root = PathBuf::from(format!("/sys/bus/pci/devices/{}/hwmon", c.pci));
    for entry in fs::read_dir(root)? {
        let p = entry?.path();
        if fs::read_to_string(p.join("name")).is_ok_and(|s| s.trim() == "pex88096") {
            let t = fs::read_to_string(p.join("temp1_input"))?
                .trim()
                .parse::<f64>()?
                / 1000.;
            if t.is_finite() && (0.0..150.0).contains(&t) {
                return Ok(t);
            }
            return Err("invalid switch temperature".into());
        }
    }
    Err("PEX88096 hwmon sensor unavailable".into())
}
fn safe_to_restore(c: &Config) -> bool {
    temperature(c).is_ok_and(|t| t < 75.)
        && gpu::read(&c.gpu_pci).is_ok_and(|g| gpu::protection(&g) == 0)
}
fn atomic_json(path: &Path, value: &serde_json::Value) -> Result<()> {
    let tmp = path.with_extension("tmp");
    fs::write(&tmp, format!("{value}\n"))?;
    fs::rename(tmp, path)?;
    Ok(())
}
fn snapshot(
    c: &Config,
    s: &protocol::Status,
    temp: f64,
    gpus: &[gpu::Gpu],
    reason: &str,
) -> serde_json::Value {
    json!({"time":timestamp(), "switch_c":temp, "fan_probe_c":s.probe_c,
        "pwm":s.pwm,"rpm":s.rpm,"manual":s.manual,"alarm_raw":s.alarm,
        "gpus":gpus.iter().map(gpu::Gpu::json).collect::<Vec<_>>(),
        "gpu_request_pwm":gpu::request(gpus), "policy":reason,"parameters":s.parameters(),
        "pci":c.pci,"address":c.address})
}
fn lock(c: &Config) -> Result<File> {
    lock_at(&c.state)
}
fn lock_at(state: &Path) -> Result<File> {
    fs::create_dir_all(state)?;
    let f = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(state.join("lock"))?;
    // SAFETY: the descriptor remains owned by File until the entire operation ends.
    if unsafe { libc::flock(f.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        return Err("another fan-feedback process holds the device lock".into());
    }
    Ok(f)
}

fn calibrate(c: &Config, stages: &str) -> Result<()> {
    let stages: Vec<(u8, u64)> = stages
        .split(',')
        .map(|s| -> Result<_> {
            let (p, d) = s.split_once(':').ok_or("stages use PWM:seconds")?;
            let pwm = p.parse::<u8>()?;
            let duration = d.parse::<u64>()?;
            if !(30..=100).contains(&pwm) || !(1..=1800).contains(&duration) {
                return Err("calibration stage outside limits".into());
            }
            Ok((pwm, duration))
        })
        .collect::<Result<_>>()?;
    let _lock = lock(c)?;
    // Require a working sensor before making any control write.
    if !safe_to_restore(c) {
        return Err("too hot to start calibration".into());
    }
    let mut fan = Fan::connect(&c.address, &c.adapter)?;
    let original = fan.original.clone().ok_or("missing original status")?;
    let path = c
        .state
        .join(format!("calibration-{}.jsonl", timestamp() as u64));
    let mut log = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(&path)?;
    writeln!(
        log,
        "{}",
        json!({"event":"baseline","time":timestamp(),"original_raw":original.raw.to_vec(),"stages":stages})
    )?;
    eprintln!("Calibration log: {}", path.display());
    let result = (|| -> Result<()> {
        for (pwm, seconds) in stages {
            if STOP.load(Ordering::Relaxed) {
                return Err("calibration interrupted".into());
            }
            fan.set_speed(pwm)?;
            let until = Instant::now() + Duration::from_secs(seconds);
            let mut next = Instant::now();
            while Instant::now() < until {
                fan.process(Duration::from_millis(250))?;
                if STOP.load(Ordering::Relaxed) {
                    return Err("calibration interrupted".into());
                }
                if Instant::now() < next {
                    continue;
                }
                next = Instant::now() + Duration::from_secs(5);
                let temp = temperature(c)?;
                let gpus = gpu::read(&c.gpu_pci)?;
                let s = fan.status()?;
                if temp >= 75.
                    || gpu::protection(&gpus) >= 80
                    || (s.rpm < 300 && Instant::now() + Duration::from_secs(10) < until)
                {
                    return Err("calibration aborted: hot chip or low fan RPM".into());
                }
                if !s.manual || s.pwm != pwm || s.parameters() != original.parameters() {
                    return Err("fan state changed during calibration".into());
                }
                let sample = snapshot(c, &s, temp, &gpus, "calibration");
                writeln!(log, "{sample}")?;
                println!("{sample}");
            }
        }
        Ok(())
    })();
    let restoration = if safe_to_restore(c) {
        fan.restore(&original)
    } else {
        fan.fallback(100)
    };
    writeln!(
        log,
        "{}",
        json!({"event":"finished","time":timestamp(),"success":result.is_ok(),"error":result.as_ref().err().map(ToString::to_string),"restored":restoration.is_ok()})
    )?;
    restoration?;
    result
}

fn connected_loop(c: &Config, fan: &mut Fan) -> Result<()> {
    let original = fan.original.clone().ok_or("missing baseline")?;
    let mut policy = Policy::new(c.minimum);
    // Reconnecting to an inherited fallback PWM must also use the recovery
    // path, rather than taking half an hour to undo a previous session's fault.
    if fan.status()?.pwm >= c.fallback {
        policy.sensor_fault(c.fallback);
    }
    let start = Instant::now();
    let mut next = Instant::now();
    let mut heartbeat = Instant::now();
    let mut faults = 0;
    let result = (|| -> Result<()> {
        while !STOP.load(Ordering::Relaxed) {
            fan.process(Duration::from_millis(250))?;
            if Instant::now() < next {
                continue;
            }
            next = Instant::now() + Duration::from_secs(5);
            let sensors = (|| -> Result<_> { Ok((temperature(c)?, gpu::read(&c.gpu_pci)?)) })();
            let (temp, gpus) = match sensors {
                Ok(readings) => readings,
                Err(e) => {
                    if !policy.sensor_fault_latched() {
                        eprintln!("Thermal telemetry failed; requesting fallback PWM: {e}");
                    }
                    policy.sensor_fault(c.fallback);
                    fan.fallback(c.fallback)?;
                    atomic_json(
                        &c.state.join("status.json"),
                        &json!({"time":timestamp(),"policy":"sensor-fault","error":e.to_string(),"fallback_pwm":c.fallback,"confirmed":true}),
                    )?;
                    continue;
                }
            };
            let s = fan.status()?;
            if s.parameters() != original.parameters() {
                return Err("controller parameters changed externally".into());
            }
            if s.rpm < 300 {
                faults += 1;
            } else {
                faults = 0;
            }
            if faults >= 3 {
                return Err("fan RPM stayed below 300".into());
            }
            let (quiet, mut reason) = c.quiet();
            let now = start.elapsed().as_secs();
            let target = policy.decide(
                now,
                temp,
                gpu::request(&gpus),
                gpu::protection(&gpus),
                quiet,
                s.pwm,
            );
            if let Some(phase) = policy.recovery_phase() {
                reason = phase.into();
            }
            let s = if !s.manual || target != s.pwm {
                let updated = fan.set_speed(target)?;
                policy.last_change = now;
                eprintln!(
                    "{reason}: switch={temp:.2} C, PWM={target}%, RPM={}",
                    updated.rpm
                );
                updated
            } else {
                s
            };
            let mut value = snapshot(c, &s, temp, &gpus, &reason);
            value["gpu_assist_pwm"] = json!(policy.gpu_assist);
            value["switch_request_pwm"] = json!(policy.switch_request(temp, quiet));
            atomic_json(&c.state.join("status.json"), &value)?;
            if heartbeat.elapsed() >= Duration::from_secs(60) {
                eprintln!("{value}");
                heartbeat = Instant::now();
            }
        }
        Ok(())
    })();
    if result.is_err() {
        let fallback = fan.fallback(c.fallback);
        eprintln!(
            "Session failed; fallback confirmation: {}",
            fallback.is_ok()
        );
        let _ = atomic_json(
            &c.state.join("status.json"),
            &json!({"time":timestamp(),"policy":"connection-fault","error":result.as_ref().err().map(ToString::to_string),"fallback_confirmed":fallback.is_ok()}),
        );
    } else {
        // A normal stop restores the device's original state if thermally safe.
        if safe_to_restore(c) {
            fan.restore(&original)?;
        } else {
            fan.fallback(c.fallback)?;
        }
        eprintln!("Controller stopped; exit state confirmed");
    }
    result
}
fn daemon(c: &Config) -> Result<()> {
    let _lock = lock(c)?;
    let mut initial = None;
    while !STOP.load(Ordering::Relaxed) {
        match Fan::connect(&c.address, &c.adapter) {
            Ok(mut fan) => {
                if initial.is_none() {
                    initial = fan.original.clone();
                }
                // Reconnection must not replace the pre-controller exit state
                // with a fallback PWM from a previous failed session.
                fan.original = initial.clone();
                eprintln!(
                    "Connected to {} with parameter-preserving control",
                    c.address
                );
                if let Err(e) = connected_loop(c, &mut fan) {
                    eprintln!("Control session error: {e}");
                }
            }
            Err(e) => {
                eprintln!("Connection unavailable: {e}");
                atomic_json(
                    &c.state.join("status.json"),
                    &json!({"time":timestamp(),"policy":"disconnected","error":e.to_string(),"note":"device retains its last PWM; fallback cannot be guaranteed without a BLE link"}),
                )?;
            }
        }
        for _ in 0..60 {
            if STOP.load(Ordering::Relaxed) {
                break;
            }
            thread::sleep(Duration::from_millis(250));
        }
    }
    Ok(())
}
fn run() -> Result<()> {
    let mut args = std::env::args().skip(1);
    let mut c = Config::default();
    let mut command = None;
    let mut extra = None;
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--config" => c = Config::load(Path::new(&args.next().ok_or("missing config path")?))?,
            "--state-dir" => c.state = args.next().ok_or("missing state directory")?.into(),
            "daemon" | "status" | "probe" | "calibrate" | "mode" | "host-daemon" | "host-auto"
            | "host-status" => {
                if command.replace(arg).is_some() {
                    return Err("only one command allowed".into());
                }
            }
            "--help" | "-h" => {
                println!(
                    "fan-feedback [--config PATH] [--state-dir PATH] daemon|status|probe|calibrate PWM:seconds,...|mode auto|quiet|cool|host-daemon|host-auto|host-status"
                );
                return Ok(());
            }
            _ => {
                if extra.replace(arg).is_some() {
                    return Err("unexpected argument".into());
                }
            }
        }
    }
    // SAFETY: handlers only store to a lock-free atomic and do not allocate or lock.
    unsafe {
        libc::signal(libc::SIGINT, stop as *const () as libc::sighandler_t);
        libc::signal(libc::SIGTERM, stop as *const () as libc::sighandler_t);
    }
    match command.as_deref().unwrap_or("status") {
        "daemon" => daemon(&c),
        "host-daemon" => host::daemon(&c),
        "host-auto" => host::restore(&c.host),
        "host-status" => {
            let v = host::status(&c.host)?;
            println!("{}", serde_json::to_string_pretty(&v)?);
            if v["age_seconds"].as_f64().unwrap_or(100.) > 30. {
                return Err("host controller status is stale".into());
            }
            Ok(())
        }
        "calibrate" => calibrate(&c, &extra.ok_or("missing PWM:seconds stages")?),
        "probe" => {
            let _lock = lock(&c)?;
            let fan = Fan::connect(&c.address, &c.adapter)?;
            for _ in 0..3 {
                fan.process(Duration::from_secs(1))?;
                println!(
                    "{}",
                    snapshot(
                        &c,
                        &fan.status()?,
                        temperature(&c)?,
                        &gpu::read(&c.gpu_pci)?,
                        "probe"
                    )
                );
            }
            Ok(())
        }
        "mode" => {
            let m = extra.ok_or("missing mode: auto, quiet, cool")?;
            if !["auto", "quiet", "cool"].contains(&m.as_str()) {
                return Err("invalid mode".into());
            }
            fs::write(c.state.join("mode"), format!("{m}\n"))?;
            println!("mode={m}");
            Ok(())
        }
        "status" => {
            let mut v: serde_json::Value =
                serde_json::from_str(&fs::read_to_string(c.state.join("status.json"))?)?;
            let age = timestamp() - v["time"].as_f64().ok_or("missing status timestamp")?;
            v["age_seconds"] = json!(age.round());
            v["host_case"] = match host::status(&c.host) {
                Ok(s) => s,
                Err(e) => json!({"policy":"unavailable","error":e.to_string()}),
            };
            println!("{}", serde_json::to_string_pretty(&v)?);
            if age > 30. {
                return Err("controller status is stale; check its service".into());
            }
            Ok(())
        }
        _ => unreachable!(),
    }
}
fn main() {
    if let Err(e) = run() {
        eprintln!("Error: {e}");
        std::process::exit(1);
    }
}
