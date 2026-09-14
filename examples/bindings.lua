-- Toggle the system monitor card with a key. Copy the o.bind line into
-- ~/.config/hypr/bindings.lua.
--
-- Check the key is free first:
--   grep -rn "CTRL + Y" ~/.config/hypr/ /usr/share/omarchy/default/hypr/
o.bind("SUPER + CTRL + Y", "System monitor", "omarchy-shell shell toggle ronildobraga.sysmon")
