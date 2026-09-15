# Input: package and check attribute names, grouped by output and system.
# Keep runner labels explicit so a new system cannot silently skip CI.
def runner:
  {
    "aarch64-darwin": "macos-15",
    "x86_64-darwin": "macos-15-intel",
    "aarch64-linux": "ubuntu-24.04-arm",
    "x86_64-linux": "ubuntu-24.04"
  }[.] // error("No GitHub runner configured for system \(.)");

[
  to_entries[] as $output
  | $output.value | to_entries[] as $system
  | $system.value[] as $name
  | {
      system: $system.key,
      target: (".#" + $output.key + "." + ($system.key | tojson) + "." + ($name | tojson))
    }
]
| group_by(.system)
| map({
    system: .[0].system,
    runner: (.[0].system | runner),
    targets: (map(.target) | unique)
  })
| if length == 0 then error("The flake exports no packages or checks")
  else {include: .}
  end
