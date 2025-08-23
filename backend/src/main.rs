let allowed = [
    "target-ssh",
    "target-serial",
    "pi400-hid",   // <— statt pi400-gadget-extra
    "kiosk",
]
.into_iter()
.map(|s| s.to_string())
.collect::<HashSet<_>>();
