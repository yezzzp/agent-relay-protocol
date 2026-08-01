# Agent Relay Protocol

**Una capa de convenciones para que varios agentes de código trabajen sobre el mismo proyecto sin pisarse ni perder contexto.**

ARP no es un harness ni un framework: no corre el bucle del agente ni reemplaza a tus
herramientas. Se monta encima de **Claude Code** y **Codex CLI**, y les da un contrato
común para saber dónde está el trabajo, quién lo tiene y cómo se cede.

---

## El problema

Trabajas con un agente y a mitad de una tarea se acaba la cuota del plan. Abres el otro
agente y empieza en frío: no sabe qué se hizo, ni por qué se descartó el primer enfoque,
ni cuál era el siguiente paso. Le vuelves a explicar todo. Vuelve a discutir decisiones
que ya estaban tomadas. A veces rehace trabajo que ya existía.

El contexto no está en ningún lado. Vive en la ventana de conversación del agente que
se quedó sin turnos.

ARP resuelve exactamente eso, con tres piezas:

1. **Un contrato escrito** en `AGENTS.md` que ambos agentes leen en cada turno.
2. **Un handoff en disco** con la intención de la tarea — no el diff, que ya lo da `git`.
3. **Un puente de cuota** que detecta el corte *antes* de que ocurra y dispara el relevo solo.

## Qué hace y qué no

| Sí | No |
|---|---|
| Define dónde vive el estado de una tarea | Corre el bucle del agente |
| Da skills portables a Claude Code y Codex CLI | Reemplaza tu CLI ni tu editor |
| Detecta el corte de cuota y cede la tarea | Envía nada fuera de tu máquina |
| Adopta proyectos existentes sin romper nada | Toca código de tu aplicación |

Todo es bash, `git` y archivos Markdown. Sin dependencias de red, sin telemetría.

---

## Instalación

```bash
git clone https://github.com/yezzzp/agent-relay-protocol.git
cd agent-relay-protocol
./install.sh
```

El instalador abre un selector para elegir a qué agentes instalar, comprueba las
dependencias y ofrece activar el puente de cuota.

> **El repo clonado *es* la instalación.** Todo se enlaza por symlink desde ahí, así que
> un `git pull` actualiza todo y lo que edites tiene efecto inmediato. No muevas la carpeta.

Sin interacción:

```bash
./install.sh --agents claude,codex   # agentes concretos
./install.sh --all --yes             # todo lo detectado, sin preguntar
```

Enlaza `agent-init`, `arp` y `arp-hooks` en `~/.local/bin`, y las skills en
`~/.claude/skills` (Claude Code) y `~/.agents/skills` (Codex CLI). Nunca sobrescribe
una skill que no sea suya.

### Requisitos

| | Para qué |
|---|---|
| `bash`, `git` | núcleo — imprescindible |
| `jq`, `python3` | puente de cuota |
| `uv` | Graphify, opcional (análisis de dependencias) |

---

## Adoptar un proyecto

Desde la raíz de cualquier proyecto:

```bash
agent-init
```

El trabajo se reparte en dos:

- **El script** hace lo determinista: crea `docs/ai/tasks/`, inyecta el bloque del
  protocolo en `AGENTS.md` y en `.gitignore` entre marcadores, y detecta el stack
  (uv, Poetry, pnpm, npm, Go, Rust, más `Makefile`/`justfile`). Es idempotente:
  correrlo N veces da el mismo resultado.
- **El agente** hace lo que requiere criterio: entrevista, consolida reglas divergentes
  y redacta las secciones 1 a 7 de `AGENTS.md`. Tiene prohibido preguntar lo que puede
  leer del repo.

Si tienes Graphify instalado, `agent-init` te ofrece además construir el grafo de
dependencias del proyecto. Son tres comandos suyos, no nuestros:

| | Qué deja |
|---|---|
| `graphify update .` | el grafo AST — tree-sitter local, sin LLM ni API keys, no gasta cuota |
| `graphify hook install` | hook `post-commit` que lo mantiene al día en segundo plano |
| `graphify <agente> install` | empuja al agente a consultar el grafo antes de leer archivos crudos |

El agente recibe el aviso de que el grafo existe, y de que la sección `## graphify`
la gestiona la herramienta y no debe tocarla.

```bash
agent-init --agent codex   # usar Codex CLI en vez de Claude Code
agent-init --no-agent      # solo la parte determinista
agent-init --dry-run       # ver qué haría, sin escribir nada
```

Si el proyecto ya tiene `AGENTS.md`, **se conserva**: solo se refresca la sección 8, la
del protocolo, que va delimitada por marcadores `ARP:BEGIN` / `ARP:END`. Un `CLAUDE.md`
con contenido propio se consolida en `AGENTS.md` y queda reducido a un `@AGENTS.md`.

### Qué queda en tu proyecto

```
tu-proyecto/
├── AGENTS.md              secciones 1-7 tuyas · sección 8 gestionada por ARP
├── CLAUDE.md              una línea: @AGENTS.md
├── .gitignore             + bloque ARP
└── docs/ai/tasks/
    ├── _TEMPLATE.md
    └── <slug>.md          solo cuando hay relevo
```

---

## Las skills

Se invocan con `/nombre` en Claude Code y `$nombre` en Codex CLI.

| Skill | Qué hace |
|---|---|
| `relay` | Escribe el handoff de la tarea en curso y para. |
| `resume` | Retoma una tarea que otro agente dejó a medias. |
| `commit` | Commits en Conventional Commits, atómicos y verificados. |

ARP no trae skills de planificación a propósito: el modo plan de Claude Code ya lo
hace mejor y con mejor integración. Duplicarlo solo añadía contexto en cada turno.

### El task file solo existe si hay relevo

`docs/ai/tasks/<slug>.md` se escribe **únicamente** cuando la tarea va a cambiar de
agente. Si se completa en una sola sesión, no se escribe ningún archivo — el historial
de git ya cuenta esa historia.

Y lo que se escribe es **intención**, nunca cambios:

```yaml
---
task: auth-refactor
owner: claude | codex | none
status: IN_PROGRESS | HANDOFF | DONE
branch: feat/auth
updated: 2026-07-30T14:02:11-05:00
---
```

Objetivo y **por qué**, plan como checklist, decisiones tomadas **con las alternativas
descartadas y su motivo**, estado real de la verificación, y qué no romper. Nada de
diffs ni listas de líneas: el sucesor tiene `git diff` y `git log`.

Ese apartado de alternativas descartadas es el que más valor aporta: evita que el
siguiente agente vuelva a discutir lo ya resuelto.

### Propiedad de la tarea

Un agente solo toma una tarea si `owner` es `none`, su propio nombre, o `status` es
`HANDOFF`. Si es de otro y sigue `IN_PROGRESS`, no la toca y avisa.

---

## El puente de cuota

*Solo Claude Code. Requiere `jq` y `python3`.*

Claude Code expone el consumo del plan en un único sitio — el statusline — y **los hooks
no lo reciben**. ARP tiende el puente:

```
statusline ──escribe──▶ ~/.claude/arp/quota.json ──lee──▶ hook UserPromptSubmit
                                                                    │
                                                          ¿pasó el umbral? ──▶ el agente
                                                                                entra en
                                                                                modo relevo
```

Y si el corte llega igual, un hook `StopFailure` con matcher `rate_limit` marca la tarea
activa del proyecto como `HANDOFF`, para que el otro agente la encuentre con `resume`.

### El plan, anclado al proyecto

Claude Code guarda los planes que apruebas en `~/.claude/plans/`, con un nombre derivado
de tu prompt. Eso los salva del olvido, pero no sirve para relevar: es un cajón global
donde no se distingue de qué repo es cada plan, Codex no sabe que existe, y nada lo
convierte en tarea cuando se corta la cuota.

Un hook `PostToolUse` con matcher `ExitPlanMode` lo ancla al proyecto: al aprobar un plan
guarda una copia en `.arp/current-plan.md`, con la rama y un slug ya calculado. Cuesta
cero tokens — es un hook, no entra en contexto — y se integra con el modo plan nativo en
vez de competir con él.

El plan viaja en `tool_response.plan` del payload; `tool_input` llega vacío.

Es un **borrador desechable**, no un task file. De ahí salen tres caminos:

| Qué pasa | Qué ocurre con el borrador |
|---|---|
| Terminas la tarea | lo sobrescribe el próximo plan; `docs/ai/tasks/` sigue vacío |
| Corres `/relay` | la skill lo lee y escribe el task file real, añadiendo decisiones y alternativas descartadas |
| Se corta la cuota | `arp-rate-limit.sh` lo promueve a `docs/ai/tasks/<slug>.md` con `status: HANDOFF` |

Así el principio queda intacto: **el task file solo aparece cuando hay relevo de verdad**.

```bash
arp-hooks install --threshold 80   # avisar al 80% de la ventana de 5h
arp-hooks status
arp-hooks uninstall
```

Escribe en `~/.claude/settings.json` **añadiendo, nunca reemplazando**: hace copia de
seguridad antes de tocar nada, respeta tus hooks y es idempotente. Si ya tienes un
`statusLine` propio, no lo pisa — te dice cómo integrarlo.

> El campo `rate_limits` solo aparece en los planes Pro y Max. Sin él, el puente
> queda inactivo y el resto de ARP funciona igual.

---

## Convención de commits

Conventional Commits, mensaje en inglés:

```
tipo(scope): asunto en imperativo

Cuerpo a 72 columnas cuando corresponda. Dice POR QUÉ, no qué —
el diff ya dice qué. Incluye las alternativas descartadas.
```

Tipos: `feat` `fix` `refactor` `docs` `test` `chore` `perf` `build` `ci`.

El cuerpo es obligatorio si el cambio toca 3 o más archivos, altera comportamiento
observable, o hubo una decisión de diseño. Con 2 archivos o menos y un cambio evidente,
basta el asunto.

Aparte existe `wip(<slug>): <paso>`, que **no** sigue estas reglas: es el commit de
relevo. Ahí entra todo con `git add -A`, sin partir en atómicos y sin exigir que la
verificación pase — el objetivo es no perder trabajo antes del corte, no dejar
historial legible.

---

## Comandos

```bash
arp status      # qué hay instalado y dónde
arp update      # git pull + reinstalación
arp where       # ruta del repo
arp uninstall   # quita enlaces y hooks — NO borra el repo ni toca tus proyectos
```

`arp update` no propaga solo el protocolo a los proyectos ya adoptados: corre
`agent-init` en cada uno para regenerar su sección 8.

---

## Estructura del repo

```
agent-relay-protocol/
├── install.sh              instalador y desinstalador
├── bin/
│   ├── agent-init          adopta el protocolo en un proyecto
│   ├── arp                 gestiona la instalación
│   └── arp-hooks           conecta el puente de cuota
├── hooks/
│   ├── arp-quota-notice.sh UserPromptSubmit — avisa antes del corte
│   ├── arp-plan-capture.sh PostToolUse — guarda el plan aprobado en .arp/
│   └── arp-rate-limit.sh   StopFailure — marca HANDOFF tras el corte
├── statusline/
│   └── arp-statusline.sh   dibuja la barra y persiste la cuota
├── lib/inject.awk          inyección idempotente entre marcadores
├── tests/run.sh            suite de los hooks — `tests/run.sh`, sin dependencias
└── templates/
    ├── AGENTS.md           plantilla canónica de 8 secciones
    ├── arp-block.md        la sección 8, regenerada en cada agent-init
    ├── task.md             plantilla de task file
    ├── skills/             relay, resume, commit
    └── stacks/             detección: uv, poetry, pnpm, npm, go, rust
```

---

## Licencia

MIT — ver [LICENSE](LICENSE).
