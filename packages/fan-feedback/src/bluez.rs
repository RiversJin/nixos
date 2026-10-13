use crate::{Result, STOP, protocol::Status};
use dbus::{
    Path,
    arg::{PropMap, RefArg, Variant},
    blocking::{
        Connection,
        stdintf::org_freedesktop_dbus::{ObjectManager, Properties, PropertiesPropertiesChanged},
    },
    message::MatchRule,
};
use std::{
    collections::HashMap,
    sync::{Arc, Mutex, atomic::Ordering},
    thread,
    time::{Duration, Instant},
};

const DEVICE: &str = "org.bluez.Device1";
const CHAR: &str = "org.bluez.GattCharacteristic1";
const ADAPTER: &str = "org.bluez.Adapter1";
const CONTROL: &str = "0000fff1-0000-1000-8000-00805f9b34fb";
const SERVICE: &str = "0000fff0-0000-1000-8000-00805f9b34fb";
type Objects = HashMap<Path<'static>, HashMap<String, PropMap>>;

#[derive(Default)]
struct Telemetry {
    status: Option<Status>,
    at: Option<Instant>,
    version: u64,
}

pub struct Fan {
    conn: Connection,
    device: String,
    characteristic: String,
    connected_by_us: bool,
    notifying: bool,
    telemetry: Arc<Mutex<Telemetry>>,
    last_write: Instant,
    pub original: Option<Status>,
}

impl Fan {
    pub fn connect(address: &str, adapter: &str) -> Result<Self> {
        let conn = Connection::new_system()?;
        let ap = format!("/org/bluez/{adapter}");
        let objects = || -> Result<Objects> {
            Ok(conn
                .with_proxy("org.bluez", "/", Duration::from_secs(5))
                .get_managed_objects()?)
        };
        let find = |objects: Objects| -> Option<String> {
            objects.into_iter().find_map(|(path, ifaces)| {
                let props = ifaces.get(DEVICE)?;
                let a = props.get("Address")?.0.as_str()?;
                (a.eq_ignore_ascii_case(address) && path.starts_with(&format!("{ap}/")))
                    .then(|| path.to_string())
            })
        };
        let device = if let Some(path) = find(objects()?) {
            path
        } else {
            let proxy = conn.with_proxy("org.bluez", ap.as_str(), Duration::from_secs(5));
            let mut filter: PropMap = HashMap::new();
            filter.insert("Transport".into(), Variant(Box::new("le".to_string())));
            proxy.method_call::<(), _, _, _>(ADAPTER, "SetDiscoveryFilter", (filter,))?;
            proxy.method_call::<(), _, _, _>(ADAPTER, "StartDiscovery", ())?;
            let discovered = (|| -> Result<String> {
                let deadline = Instant::now() + Duration::from_secs(20);
                loop {
                    if STOP.load(Ordering::Relaxed) {
                        return Err("interrupted during discovery".into());
                    }
                    if let Some(path) = find(objects()?) {
                        return Ok(path);
                    }
                    if Instant::now() >= deadline {
                        return Err("fan not advertising; release its phone connection".into());
                    }
                    conn.process(Duration::from_millis(250))?;
                }
            })();
            let _ = proxy.method_call::<(), _, _, _>(ADAPTER, "StopDiscovery", ());
            discovered?
        };
        // Do not take over a connection owned by another desktop/phone client.
        let dp = conn.with_proxy("org.bluez", device.as_str(), Duration::from_secs(20));
        if dp.get::<bool>(DEVICE, "Connected")? {
            return Err("fan already connected by another client".into());
        }
        dp.method_call::<(), _, _, _>(DEVICE, "Connect", ())?;
        let mut fan = Self {
            conn,
            device,
            characteristic: String::new(),
            connected_by_us: true,
            notifying: false,
            telemetry: Arc::new(Mutex::new(Telemetry::default())),
            last_write: Instant::now() - Duration::from_secs(1),
            original: None,
        };
        let deadline = Instant::now() + Duration::from_secs(20);
        loop {
            let proxy =
                fan.conn
                    .with_proxy("org.bluez", fan.device.as_str(), Duration::from_secs(3));
            if proxy.get::<bool>(DEVICE, "ServicesResolved")? {
                break;
            }
            if Instant::now() >= deadline || STOP.load(Ordering::Relaxed) {
                return Err("GATT service discovery timed out".into());
            }
            fan.conn.process(Duration::from_millis(250))?;
        }
        let objects: Objects = fan
            .conn
            .with_proxy("org.bluez", "/", Duration::from_secs(5))
            .get_managed_objects()?;
        for (path, ifaces) in &objects {
            let Some(props) = ifaces.get(CHAR) else {
                continue;
            };
            if !path.starts_with(&format!("{}/", fan.device)) {
                continue;
            }
            if props.get("UUID").and_then(|v| v.0.as_str()) != Some(CONTROL) {
                continue;
            }
            let Some(service) = props.get("Service").and_then(|v| v.0.as_str()) else {
                continue;
            };
            let sp = objects
                .iter()
                .find(|(p, _)| p.to_string() == service)
                .and_then(|(_, i)| i.get("org.bluez.GattService1"));
            if sp.and_then(|p| p.get("UUID")).and_then(|v| v.0.as_str()) != Some(SERVICE) {
                continue;
            }
            let flags: Vec<String> = props
                .get("Flags")
                .and_then(|v| v.0.as_iter())
                .map(|it| it.filter_map(|v| v.as_str().map(str::to_string)).collect())
                .unwrap_or_default();
            if !flags.iter().any(|v| v == "notify")
                || !flags.iter().any(|v| v == "write-without-response")
            {
                return Err("unexpected GATT permissions".into());
            }
            fan.characteristic = path.to_string();
            break;
        }
        if fan.characteristic.is_empty() {
            return Err("expected Haicon service/characteristic missing".into());
        }
        let telemetry = fan.telemetry.clone();
        fan.conn.add_match(
            MatchRule::new_signal("org.freedesktop.DBus.Properties", "PropertiesChanged")
                .with_path(fan.characteristic.clone())
                .with_sender("org.bluez"),
            move |p: PropertiesPropertiesChanged, _, _| {
                if p.interface_name == CHAR {
                    if let Some(bytes) = p
                        .changed_properties
                        .get("Value")
                        .and_then(|v| v.0.as_iter())
                    {
                        let raw: Vec<u8> = bytes
                            .filter_map(|v| v.as_u64().and_then(|n| u8::try_from(n).ok()))
                            .collect();
                        if let Some(status) = Status::decode(&raw) {
                            let mut t = telemetry.lock().unwrap();
                            t.status = Some(status);
                            t.at = Some(Instant::now());
                            t.version += 1;
                        }
                    }
                }
                true
            },
        )?;
        fan.conn
            .with_proxy(
                "org.bluez",
                fan.characteristic.as_str(),
                Duration::from_secs(5),
            )
            .method_call::<(), _, _, _>(CHAR, "StartNotify", ())?;
        fan.notifying = true;
        fan.write(&[0x61, 0x61])?;
        fan.wait(|_| true, 0, Duration::from_secs(15))?;
        fan.original = Some(fan.status()?);
        Ok(fan)
    }
    pub fn process(&self, timeout: Duration) -> Result<()> {
        self.conn.process(timeout)?;
        Ok(())
    }
    pub fn status(&self) -> Result<Status> {
        let t = self.telemetry.lock().unwrap();
        if t.at.is_none_or(|at| at.elapsed() > Duration::from_secs(10)) {
            return Err("fan telemetry stale".into());
        }
        Ok(t.status.clone().ok_or("no valid fan status")?)
    }
    fn version(&self) -> u64 {
        self.telemetry.lock().unwrap().version
    }
    fn wait(
        &self,
        predicate: impl Fn(&Status) -> bool,
        after: u64,
        timeout: Duration,
    ) -> Result<Status> {
        let deadline = Instant::now() + timeout;
        loop {
            {
                let t = self.telemetry.lock().unwrap();
                if t.version > after {
                    if let Some(s) = &t.status {
                        if predicate(s) {
                            return Ok(s.clone());
                        }
                    }
                }
            }
            if Instant::now() >= deadline {
                return Err("fan did not confirm requested state".into());
            }
            self.process(Duration::from_millis(100))?;
        }
    }
    fn write(&mut self, bytes: &[u8]) -> Result<()> {
        thread::sleep(Duration::from_millis(250).saturating_sub(self.last_write.elapsed()));
        let mut opts: PropMap = HashMap::new();
        opts.insert("type".into(), Variant(Box::new("command".to_string())));
        self.conn
            .with_proxy(
                "org.bluez",
                self.characteristic.as_str(),
                Duration::from_secs(3),
            )
            .method_call::<(), _, _, _>(CHAR, "WriteValue", (bytes.to_vec(), opts))?;
        self.last_write = Instant::now();
        Ok(())
    }
    pub fn set_speed(&mut self, pwm: u8) -> Result<Status> {
        if pwm > 100 {
            return Err("invalid PWM".into());
        }
        let baseline = self.status()?;
        if !baseline.manual {
            self.write(&[0x11, pwm, 0x11])?;
            self.set_mode(&baseline, true)?;
        }
        for _ in 0..3 {
            let version = self.version();
            self.write(&[0x11, pwm, 0x11])?;
            if let Ok(status) = self.wait(
                |s| s.manual && s.pwm == pwm && s.parameters() == baseline.parameters(),
                version,
                Duration::from_secs(3),
            ) {
                return Ok(status);
            }
        }
        Err("PWM confirmation failed".into())
    }
    fn set_mode(&mut self, baseline: &Status, manual: bool) -> Result<()> {
        for _ in 0..3 {
            let version = self.version();
            self.write(&baseline.mode_command(manual))?;
            if self
                .wait(
                    |s| s.manual == manual && s.parameters() == baseline.parameters(),
                    version,
                    Duration::from_secs(3),
                )
                .is_ok()
            {
                return Ok(());
            }
        }
        Err("mode confirmation failed".into())
    }
    pub fn restore(&mut self, original: &Status) -> Result<()> {
        if original.manual {
            self.set_speed(original.pwm)?;
        }
        self.set_mode(original, original.manual)
    }
    pub fn fallback(&mut self, pwm: u8) -> Result<()> {
        // If status is stale, a best-effort high PWM must still be attempted.
        if self.status().is_ok() {
            self.set_speed(pwm)?;
        } else {
            let baseline = self.original.clone().ok_or("no baseline for fallback")?;
            self.write(&[0x11, pwm, 0x11])?;
            self.write(&baseline.mode_command(true))?;
            self.write(&[0x11, pwm, 0x11])?;
            return Err("fallback sent but telemetry unavailable to confirm it".into());
        }
        Ok(())
    }
}

impl Drop for Fan {
    fn drop(&mut self) {
        if self.notifying {
            let _ = self
                .conn
                .with_proxy(
                    "org.bluez",
                    self.characteristic.as_str(),
                    Duration::from_secs(2),
                )
                .method_call::<(), _, _, _>(CHAR, "StopNotify", ());
        }
        if self.connected_by_us {
            let _ = self
                .conn
                .with_proxy("org.bluez", self.device.as_str(), Duration::from_secs(2))
                .method_call::<(), _, _, _>(DEVICE, "Disconnect", ());
        }
    }
}
