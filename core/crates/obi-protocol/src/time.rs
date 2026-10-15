//! The protocol's timestamps: RFC 3339 in UTC with a `Z` and whole seconds, exactly 20 characters
//! (`2026-10-14T12:00:00Z`, common.schema.json's `timestamp`), as seconds since the Unix epoch.

/// Seconds since the epoch of a protocol timestamp, or `None` when it isn't one or names a date
/// that doesn't exist (February 30th).
pub fn parse(text: &str) -> Option<i64> {
    parse_with(text, true)
}

/// [`parse`], but a day past the month's end rolls over into the next month (February 30th is
/// March 2nd), as ECMAScript's `Date.parse` reads it: what the reference verifier does with the
/// times it only compares (an audit entry's `recorded_at`, the verifier's own `now`).
pub fn parse_lenient(text: &str) -> Option<i64> {
    parse_with(text, false)
}

fn parse_with(text: &str, strict: bool) -> Option<i64> {
    let b = text.as_bytes();
    if b.len() != 20
        || b[4] != b'-'
        || b[7] != b'-'
        || b[10] != b'T'
        || b[13] != b':'
        || b[16] != b':'
        || b[19] != b'Z'
    {
        return None;
    }
    let number = |range: std::ops::Range<usize>| -> Option<i64> {
        let part = &b[range];
        if !part.iter().all(u8::is_ascii_digit) {
            return None;
        }
        Some(part.iter().fold(0i64, |n, d| n * 10 + i64::from(d - b'0')))
    };
    let (year, month, day) = (number(0..4)?, number(5..7)?, number(8..10)?);
    let (hour, minute, second) = (number(11..13)?, number(14..16)?, number(17..19)?);
    if !(1..=12).contains(&month)
        || day < 1
        || day
            > if strict {
                days_in_month(year, month)
            } else {
                31
            }
        || hour > 23
        || minute > 59
        || second > 59
    {
        return None;
    }
    Some(days_from_civil(year, month, day) * 86_400 + hour * 3_600 + minute * 60 + second)
}

/// The protocol timestamp of `seconds` since the epoch.
pub fn format(seconds: i64) -> String {
    let days = seconds.div_euclid(86_400);
    let rest = seconds.rem_euclid(86_400);
    let (year, month, day) = civil_from_days(days);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        rest / 3_600,
        rest % 3_600 / 60,
        rest % 60
    )
}

/// Now, as seconds since the epoch.
pub fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

fn is_leap(year: i64) -> bool {
    year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
}

fn days_in_month(year: i64, month: i64) -> i64 {
    match month {
        2 if is_leap(year) => 29,
        2 => 28,
        4 | 6 | 9 | 11 => 30,
        _ => 31,
    }
}

/// Days since 1970-01-01 of a proleptic Gregorian date (Howard Hinnant's algorithm).
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let y = if month <= 2 { year - 1 } else { year };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (month + 9) % 12;
    let doy = (153 * mp + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

fn civil_from_days(days: i64) -> (i64, i64, i64) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    (year, month, day)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips() {
        for text in [
            "1970-01-01T00:00:00Z",
            "2026-10-14T12:00:00Z",
            "2024-02-29T23:59:59Z",
            "2000-03-01T00:00:00Z",
            "9999-12-31T23:59:59Z",
            "0001-01-01T00:00:00Z",
        ] {
            assert_eq!(format(parse(text).unwrap()), text);
        }
        assert_eq!(parse("2026-10-14T12:00:00Z"), Some(1_791_979_200));
    }

    #[test]
    fn refuses_what_isnt_one() {
        for text in [
            "2026-02-29T00:00:00Z",
            "2026-02-30T00:00:00Z",
            "2026-13-01T00:00:00Z",
            "2026-04-31T00:00:00Z",
            "2026-10-14T24:00:00Z",
            "2026-10-14T12:00:60Z",
            "2026-10-14T12:00:00.000Z",
            "2026-10-14 12:00:00Z",
            "2026-10-14T12:00:00+00:00",
            "+026-10-14T12:00:00Z",
            "",
        ] {
            assert_eq!(parse(text), None, "{text}");
        }
    }

    #[test]
    fn lenient_days_roll_over() {
        assert_eq!(
            parse_lenient("2026-02-30T00:00:00Z"),
            parse("2026-03-02T00:00:00Z")
        );
        assert_eq!(parse_lenient("2026-02-32T00:00:00Z"), None);
        assert_eq!(parse("2026-02-30T00:00:00Z"), None);
    }
}
