# Inserts or replaces a block delimited by ARP:BEGIN / ARP:END marker lines.
#
#   awk -v BLOCK=path/to/block -f inject.awk file > file.new
#
# A marker is a line that holds only the marker, as an HTML comment
# (<!-- ARP:BEGIN v2 -->) or a hash comment (# ARP:BEGIN). A line that merely
# mentions the marker in prose is left alone. If a BEGIN has no END, nothing
# after it is dropped. Without a block, it is appended. Running it N times
# always leaves exactly one copy.

function is_marker(s, word) {
    return s ~ ("^[ \t]*(<!--|#)[ \t]*ARP:" word "([ \t][^>]*)?[ \t]*(-->)?[ \t]*$")
}

BEGIN {
    while ((getline line < BLOCK) > 0) blk = blk line "\n"
    close(BLOCK)
    found = 0; skip = 0; held = ""
}

is_marker($0, "BEGIN") && !found { printf "%s", blk; found = 1; skip = 1; held = ""; next }
skip && is_marker($0, "END")      { skip = 0; held = ""; next }
skip                              { held = held $0 "\n"; next }
                                  { print }

END {
    if (skip) printf "%s", held
    if (!found) printf "\n%s", blk
}
