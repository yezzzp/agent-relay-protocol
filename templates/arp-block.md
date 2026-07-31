<!-- ARP:BEGIN v1 -->
## 8. Protocolo de agentes (ARP)

Bloque gestionado por `agent-init`. No editar a mano: se regenera en cada ejecución.

### Verificación
Ningún paso se marca `[x]` sin que el comando de verificación de la sección 3 pase.
La opinión del agente no sustituye al comando.

Al escribir tests: el test se escribe primero y **debe fallar** antes de implementar.
Un test que pasa recién escrito está mal planteado.

### Task files — solo para relevo
`docs/ai/tasks/<slug>.md` se escribe **únicamente** cuando la tarea va a cambiar de agente:
porque el usuario lo pide (`/relay` en Claude, `$relay` en Codex) o porque el aviso de cuota
lo indica.

Si la tarea se completa en una sola sesión, **no se escribe ningún archivo**.

`.arp/current-plan.md` es otra cosa: un borrador desechable que un hook escribe solo al
aprobar un plan en modo plan. No es un task file, no se commitea y no se edita a mano.
Lo lee `relay` para no partir de cero, y lo promueve el hook de cuota si el corte llega
antes. Que exista no significa que haya una tarea en curso.

Frontmatter obligatorio:

```yaml
---
task: <slug>
owner: claude | codex | none
status: IN_PROGRESS | HANDOFF | DONE
branch: <rama>
updated: <ISO-8601>
---
```

### Propiedad de la tarea
- Solo tomas una tarea si `owner` es `none`, tu propio nombre, o `status` es `HANDOFF`.
- Si `owner` es otro agente y `status` es `IN_PROGRESS`: no toques nada, avisa al usuario.
- Al tomarla: escribe tu nombre en `owner`, pon `status: IN_PROGRESS`, actualiza `updated`.

### En modo relevo
1. Escribe el task file **antes** de tocar código.
2. Al cerrar cada paso: marca `[x]`, actualiza el task file y haz un commit de relevo.
   El corte por cuota es abrupto — lo que no está en disco se pierde.
3. Registra decisiones tomadas y alternativas descartadas. El sucesor no debe re-litigarlas.

### Commits de relevo (`wip`)
Un punto de guardado, no una entrada del historial. Formato único:

```
git add -A && git commit -m "wip(<slug>): <paso donde quedó>"
```

`git add -A` a propósito: entra todo, incluido lo que está a medias. **No** se parte en
commits atómicos y **no** se exige que la verificación pase — se commitea en rojo si hace
falta. Salvar el trabajo es lo único que importa aquí.

Solo aplica a `wip`. Cualquier otro commit sigue la convención de la skill `commit`.

### Al retomar (`/resume`, `$resume`)
1. Lee el task file, luego `git log` y `git diff` para ver el estado real.
2. Ejecuta el comando de verificación antes de escribir código.
3. Continúa desde la primera casilla `[ ]`. No repitas trabajo hecho ni re-discutas lo decidido.

### Qué NO va en el task file
Lo que `git diff` o `git log` ya dicen. El archivo guarda **intención**, no cambios:
objetivo, plan, decisiones, riesgos y qué no tocar.
<!-- ARP:END -->
