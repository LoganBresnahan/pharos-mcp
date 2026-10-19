//! Just enough JSON for the hello preamble: writing strings and flat
//! objects, and reading one field of the daemon's flat, one-line ack.
//! The shim never parses MCP traffic; it relays it as bytes.

/// `s` as a JSON string literal.
pub fn string(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// The string value of `key` in a flat JSON object (no nesting before
/// the key), unescaped. `None` when absent or not a string.
pub fn get_string(json: &str, key: &str) -> Option<String> {
    let rest = after_key(json, key)?;
    let rest = rest.strip_prefix('"')?;
    let mut out = String::new();
    let mut chars = rest.chars();
    while let Some(c) = chars.next() {
        match c {
            '"' => return Some(out),
            '\\' => match chars.next()? {
                'n' => out.push('\n'),
                'r' => out.push('\r'),
                't' => out.push('\t'),
                'b' => out.push('\u{8}'),
                'f' => out.push('\u{c}'),
                'u' => {
                    let hex: String = chars.by_ref().take(4).collect();
                    out.push(
                        char::from_u32(u32::from_str_radix(&hex, 16).ok()?).unwrap_or('\u{fffd}'),
                    );
                }
                other => out.push(other),
            },
            c => out.push(c),
        }
    }
    None
}

/// Whether `key` appears as a top-level key of a flat JSON object.
pub fn has_key(json: &str, key: &str) -> bool {
    after_key(json, key).is_some()
}

fn after_key<'a>(json: &'a str, key: &str) -> Option<&'a str> {
    let needle = string(key);
    let at = json.find(&needle)?;
    let rest = json[at + needle.len()..].trim_start();
    Some(rest.strip_prefix(':')?.trim_start())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn escapes_quotes_backslashes_and_controls() {
        assert_eq!(string("a\"b\\c\nd\u{1}"), "\"a\\\"b\\\\c\\nd\\u0001\"");
        assert_eq!(string("ünï"), "\"ünï\"");
    }

    #[test]
    fn reads_the_ack_fields() {
        let ok = r#"{"pharos_hello_ok":1,"session":"s3","daemon_pid":42}"#;
        assert!(has_key(ok, "pharos_hello_ok"));
        assert_eq!(get_string(ok, "session").as_deref(), Some("s3"));
        let err = r#"{"pharos_hello_error":"build mismatch: \"a\" vs b"}"#;
        assert!(!has_key(err, "pharos_hello_ok"));
        assert_eq!(
            get_string(err, "pharos_hello_error").as_deref(),
            Some("build mismatch: \"a\" vs b")
        );
    }

    #[test]
    fn round_trips_through_escape_and_read() {
        let value = "tab\there \"quoted\" \\ back";
        let json = format!("{{\"k\":{}}}", string(value));
        assert_eq!(get_string(&json, "k").as_deref(), Some(value));
    }
}
