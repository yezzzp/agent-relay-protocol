# Inyecta o reemplaza un bloque delimitado por ARP:BEGIN / ARP:END.
#
#   awk -v BLOCK=ruta/al/bloque -f inject.awk archivo > archivo.new
#
# Agnóstico al estilo de comentario: sirve igual para markdown (<!-- -->)
# que para .gitignore (#). Si el bloque no existe, lo agrega al final.
# Idempotente: ejecutarlo N veces deja siempre una sola copia.

BEGIN {
    while ((getline line < BLOCK) > 0) blk = blk line "\n"
    close(BLOCK)
    found = 0
    skip  = 0
}

/ARP:BEGIN/ { printf "%s", blk; found = 1; skip = 1; next }
/ARP:END/   { skip = 0; next }
skip        { next }
            { print }

END { if (!found) printf "\n%s", blk }
