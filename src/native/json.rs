use janetrs::{
    client::JanetClient, env::CFunOptions, Janet, JanetArray, JanetBuffer, JanetKeyword,
    JanetString, JanetTable,
};

/// Convert a Janet value to a serde_json::Value.
fn janet_to_json(val: Janet) -> serde_json::Value {
    use serde_json::Value;

    if val.is_nil() {
        Value::Null
    } else if let Ok(b) = val.try_unwrap::<bool>() {
        Value::Bool(b)
    } else if let Ok(n) = val.try_unwrap::<f64>() {
        // Represent integers without decimal point
        if n.fract() == 0.0 && n.abs() < (i64::MAX as f64) {
            Value::Number(serde_json::Number::from(n as i64))
        } else {
            serde_json::Number::from_f64(n)
                .map(Value::Number)
                .unwrap_or(Value::Null)
        }
    } else if let Ok(s) = val.try_unwrap::<JanetString>() {
        Value::String(String::from_utf8_lossy(s.as_bytes()).into_owned())
    } else if let Ok(kw) = val.try_unwrap::<JanetKeyword>() {
        Value::String(String::from_utf8_lossy(kw.as_bytes()).into_owned())
    } else if let Ok(sym) = val.try_unwrap::<janetrs::JanetSymbol>() {
        Value::String(String::from_utf8_lossy(sym.as_bytes()).into_owned())
    } else if let Ok(arr) = val.try_unwrap::<JanetArray>() {
        let items: Vec<Value> = arr.iter().map(|v| janet_to_json(*v)).collect();
        Value::Array(items)
    } else if let Ok(tup) = val.try_unwrap::<janetrs::JanetTuple>() {
        let items: Vec<Value> = tup.iter().map(|v| janet_to_json(*v)).collect();
        Value::Array(items)
    } else if let Ok(tbl) = val.try_unwrap::<JanetTable>() {
        let mut map = serde_json::Map::new();
        for (k, v) in tbl.iter() {
            let key = janet_key_to_string(*k);
            map.insert(key, janet_to_json(*v));
        }
        Value::Object(map)
    } else if let Ok(st) = val.try_unwrap::<janetrs::JanetStruct>() {
        let mut map = serde_json::Map::new();
        for (k, v) in st.iter() {
            let key = janet_key_to_string(*k);
            map.insert(key, janet_to_json(*v));
        }
        Value::Object(map)
    } else {
        // Fallback: convert to string representation
        Value::Null
    }
}

/// Convert a Janet value used as a dictionary key to a String.
fn janet_key_to_string(val: Janet) -> String {
    if let Ok(s) = val.try_unwrap::<JanetString>() {
        String::from_utf8_lossy(s.as_bytes()).into_owned()
    } else if let Ok(kw) = val.try_unwrap::<JanetKeyword>() {
        String::from_utf8_lossy(kw.as_bytes()).into_owned()
    } else if let Ok(sym) = val.try_unwrap::<janetrs::JanetSymbol>() {
        String::from_utf8_lossy(sym.as_bytes()).into_owned()
    } else {
        format!("{}", val)
    }
}

/// Convert a serde_json::Value to a Janet value.
fn json_to_janet(val: &serde_json::Value) -> Janet {
    use serde_json::Value;

    match val {
        Value::Null => Janet::nil(),
        Value::Bool(b) => Janet::boolean(*b),
        Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                Janet::number(i as f64)
            } else if let Some(f) = n.as_f64() {
                Janet::number(f)
            } else {
                Janet::nil()
            }
        }
        Value::String(s) => Janet::from(JanetString::new(s.as_bytes())),
        Value::Array(arr) => {
            let mut janet_arr = JanetArray::with_capacity(arr.len());
            for item in arr {
                janet_arr.push(json_to_janet(item));
            }
            Janet::from(janet_arr)
        }
        Value::Object(map) => {
            let mut table = JanetTable::with_capacity(map.len());
            for (k, v) in map {
                // Use keywords for keys — idiomatic Janet, matches {:key val} access
                table.insert(JanetKeyword::new(k.as_bytes()), json_to_janet(v));
            }
            Janet::from(table)
        }
    }
}

/// (json/encode value)
/// Encode a Janet value as a JSON string.
#[janetrs::janet_fn(arity(fix(1)))]
fn encode(args: &mut [Janet]) -> Janet {
    let json_val = janet_to_json(args[0]);
    let s = serde_json::to_string(&json_val).unwrap_or_else(|_| "null".to_string());
    Janet::from(JanetString::new(s.as_bytes()))
}

/// (json/decode str)
/// Decode a JSON string (or buffer) into a Janet value.
#[janetrs::janet_fn(arity(fix(1)))]
fn decode(args: &mut [Janet]) -> Janet {
    let str_val: String = if let Ok(s) = args[0].try_unwrap::<JanetString>() {
        std::str::from_utf8(s.as_bytes())
            .expect("json/decode: input is not valid UTF-8")
            .to_owned()
    } else if let Ok(b) = args[0].try_unwrap::<JanetBuffer>() {
        std::str::from_utf8(b.as_bytes())
            .expect("json/decode: input is not valid UTF-8")
            .to_owned()
    } else {
        panic!("json/decode expects a string or buffer");
    };

    match serde_json::from_str::<serde_json::Value>(&str_val) {
        Ok(val) => json_to_janet(&val),
        Err(e) => {
            eprintln!("json/decode error: {}", e);
            Janet::nil()
        }
    }
}

pub fn register(client: &mut JanetClient) {
    client.add_c_fn(CFunOptions::new(c"encode", encode_c).namespace(c"json"));
    client.add_c_fn(CFunOptions::new(c"decode", decode_c).namespace(c"json"));
}
