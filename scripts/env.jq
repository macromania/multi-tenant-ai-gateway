reduce inputs as $line ({};
  if ($line | test("^\\s*(#.*)?$")) then .
  elif ($line | test("^[A-Z_][A-Z0-9_]*=[^\\r\\n]*$")) then
    ($line | capture("^(?<key>[^=]+)=(?<value>.*)$")) as $entry
    | if has($entry.key) then error("Duplicate .env key: " + $entry.key)
      else .[$entry.key] = $entry.value end
  else error("Invalid .env line; use literal KEY=value without shell syntax")
  end
)
