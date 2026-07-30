---
name: commit
description: Redacta y crea commits siguiendo Conventional Commits, partiendo el trabajo en commits atómicos y verificando antes. Úsala cuando el usuario pida commitear, guardar el trabajo, o preguntar cómo dejar el árbol limpio. También al cerrar un paso de un plan.
---

# Commit — historial legible, en inglés, atómico

Un commit responde una sola pregunta: **por qué existe este cambio**. El diff ya dice
qué cambió; el mensaje no lo repite.

## 1. Mira antes de escribir

```
git status --short
git diff --staged
git diff
git log --oneline -20
```

El `git log` no es opcional: de ahí sacas los scopes que el proyecto ya usa. Reusa
los que existan en vez de inventar sinónimos (`installer` hoy, `install` mañana).

## 2. Parte el trabajo

Si el árbol mezcla cambios sin relación, **no los metas en un commit**. Agrupa por
unidad lógica y commitea una por una, `git add <archivo>` por archivo.

Cuando dos cambios sin relación viven en el mismo archivo, hace falta bajar a hunks
(`git apply --cached` con un parche). Ahí **muestra el plan de commits y espera la
aprobación del usuario** antes de tocar el índice. Es la operación donde más fácil
se rompe algo.

Si todo el árbol es una sola unidad lógica, un commit basta. No inventes divisiones.

## 3. Verifica una vez, antes de la tanda

Ejecuta el comando de verificación de la sección 3 de AGENTS.md sobre el árbol
completo, **antes** del primer commit.

Si falla: no commitees nada. Reporta el error y para.

Los commits de relevo (`wip`) quedan fuera de esta skill: son puntos de guardado, no
entradas del historial. Sus reglas están en la sección 8 de AGENTS.md.

## 4. Formato del mensaje

Todo el mensaje va en **inglés**, incluso si la conversación es en otro idioma.

```
tipo(scope): asunto en imperativo

Cuerpo a 72 columnas cuando corresponda.

BREAKING CHANGE: qué se rompe y qué hacer al respecto.
```

**Tipos:** `feat` `fix` `refactor` `docs` `test` `chore` `perf` `build` `ci`.

`refactor` no cambia comportamiento. Si lo cambia, es `feat` o `fix`.

Existe un décimo tipo, `wip`, que **no escribes con esta skill**: pertenece al protocolo
de relevo y lo define la sección 8 de AGENTS.md.

**Scope:** el directorio o módulo de primer nivel del archivo tocado, contrastado
con los del `git log`. Si el cambio es transversal, omítelo: `chore: bump ruff`.

**Asunto:** imperativo (`add`, nunca `added` ni `adds`), minúscula inicial, sin punto
final, ≤50 caracteres.

**Breaking change:** `!` antes de los dos puntos (`feat(api)!: ...`) y footer
`BREAKING CHANGE:` describiendo qué se rompe.

## 5. Cuándo lleva cuerpo

Sin cuerpo si toca ≤2 archivos **y** el cambio es evidente leyendo el asunto.

Con cuerpo, obligatorio, si se cumple cualquiera de estas:

- toca ≥3 archivos,
- cambia comportamiento observable desde fuera (API, CLI, formato de salida),
- hubo una decisión de diseño con alternativas.

El cuerpo dice **por qué**, y **qué se descartó y por qué**. Nunca enumera archivos
ni líneas: eso es el diff.

```
refactor(installer): extract TUI selection into a function

The interactive block was tangled with argument parsing, which made
--agents impossible to test without a TTY.

Dropped `dialog`: an external dependency for what amounts to 30 lines
of ANSI escapes.
```

## 6. Límites

- **Nunca hagas push.** Eso lo decide el usuario.
- No uses `git commit -a`: rompe la partición del paso 2.
- No enmiendes ni rebases commits ya publicados sin que te lo pidan.

## 7. Cierra

Una línea por commit creado: hash corto y asunto. Si paraste por verificación en
rojo o esperando aprobación de hunks, dilo y no sigas.
