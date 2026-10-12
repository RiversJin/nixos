#[derive(Clone, Debug)]
pub struct Status {
    pub raw: [u8; 27],
    pub pwm: u8,
    pub rpm: u16,
    pub manual: bool,
    pub probe_c: f64,
    pub alarm: u8,
}

impl Status {
    pub fn decode(raw: &[u8]) -> Option<Self> {
        if raw.len() != 27 || raw[0] != 0x91 || raw[26] != 0x91 || raw[1] > 100 || raw[4] > 1 {
            return None;
        }
        Some(Self {
            raw: raw.try_into().ok()?,
            pwm: raw[1],
            rpm: u16::from_be_bytes([raw[2], raw[3]]),
            manual: raw[4] == 1,
            probe_c: f64::from(u16::from_be_bytes([raw[6], raw[7]])) / 10.0,
            alarm: raw[5],
        })
    }
    pub fn parameters(&self) -> &[u8] {
        &self.raw[8..19]
    }
    pub fn mode_command(&self, manual: bool) -> [u8; 16] {
        let mut command = [0x13; 16];
        command[1] = 1;
        command[2] = u8::from(manual);
        command[3..14].copy_from_slice(self.parameters());
        command
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn reject_bad_frames_and_preserve_every_parameter() {
        let mut raw = [0u8; 27];
        raw[0] = 0x91;
        raw[26] = 0x91;
        raw[1] = 35;
        raw[8..19].copy_from_slice(&[30, 60, 3, 20, 100, 0, 8, 1, 70, 3, 20]);
        let s = Status::decode(&raw).unwrap();
        assert_eq!(&s.mode_command(true)[3..14], &raw[8..19]);
        assert_eq!(&s.mode_command(false)[..3], &[0x13, 1, 0]);
        assert!(Status::decode(&raw[..26]).is_none());
        raw[4] = 2;
        assert!(Status::decode(&raw).is_none());
        raw[4] = 0;
        raw[1] = 101;
        assert!(Status::decode(&raw).is_none());
        raw[1] = 35;
        raw[26] = 0;
        assert!(Status::decode(&raw).is_none());
    }
}
