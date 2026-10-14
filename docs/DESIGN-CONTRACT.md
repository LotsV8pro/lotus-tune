# Lotus Tune — Contrato de rediseño (leer antes de tocar QML)

Objetivo: **minimalismo absoluto**, limpio, ultra fluido, ≤200 MB RAM (app+mpv).
Cada subagente posee un conjunto **disjunto** de ficheros. No toques ficheros ajenos.

## Reglas duras (obligatorias)

1. **No rompas la API pública.** Conserva EXACTAMENTE todos los `id`, `property`,
   `signal`, `function`, `readonly property` y sus nombres. Otros ficheros los
   referencian. Puedes cambiar SOLO cómo se pinta (colores, tamaños, espaciado,
   estructura interna, animaciones), nunca la interfaz hacia fuera.
2. **Sin dependencias nuevas.** Solo `QtQuick`, `QtQuick.Layouts`, `QtQuick.Window`,
   `QtCore` y módulos ya importados. Nada de `QtQuick.Effects`, `MultiEffect`,
   `ShaderEffect`, `FastBlur`, `DropShadow`.
3. **Color solo desde el sistema.** Usa `Sys.bg`, `Sys.surface`, `Sys.surfaceAlt`,
   `Sys.border`, `Sys.borderSubtle`, `Sys.accent`, `Sys.onAccent`, `Sys.text`,
   `Sys.textDim`, `Sys.danger`. Nada de colores fijos salvo `Qt.rgba(0,0,0,x)` en
   scrims y los degradados de portada ya existentes.
4. **Movimiento sobrio.** Usa `Theme.fastMs` (120) / `Theme.medMs` (180) /
   `Theme.slowMs` (280). **Prohibido** `loops: Animation.Infinite` visible y
   animaciones > 280 ms en superficies grandes. Anima solo por interacción.
5. **Portadas con `sourceSize`** para no cargar la imagen a resolución completa
   (clave para RAM). Ej.: `sourceSize.width: 320` (minis) / `600` (portada grande).
6. **Listas virtualizadas.** Usa `ListView`/`GridView` con `reuseItems: true` y
   `cacheBuffer` razonable; evita `Repeater` sobre listas largas.
7. **Ligero:** sin sombras pesadas, sin capas extra, sin `Timer` a <100 ms.
8. El código debe **compilar** (QML válido). No ejecutes builds; lo hará el orquestador.

## Tokens (`qml/theme.js` importado como `Theme`)

- Duraciones: `fastMs 120`, `medMs 180`, `slowMs 280`.
- Radios: `rSm 6`, `rMd 10`, `rLg 14`, `rXl 18`.
- Tipos: `tXs 10 tSm 11 tMd 12 tBase 13 tLg 15 tXl 18 t2xl 22 t3xl 28`.
  Peso: secundario Light/`Font.Normal`, principal Medium/Bold. Sans geométrica.
- Espaciado: `s1 4 s2 8 s3 12 s4 16 s5 24 s6 32`.
- Ritmo: `rowH 52`, `rowCompact 46`, `rowThin 32`, `topBarH 52`, `playerBarH 56`.
- Helpers: `Theme.hover(c)`, `Theme.active(c)`, `Theme.alpha(c,a)`, `Theme.mix(a,b,t)`,
  `Theme.mmss(s)`.

## Lenguaje visual

- Superficies planas: fondo `Sys.bg`; contenedores `Sys.surface` con 1 borde
  `Sys.border`; hover `Theme.hover(Sys.surface)`.
- Jerarquía por **aire y peso**, no por líneas ni cajas. Bordes/dividers al mínimo.
- Iconos: `Glyph { kind: "..."; color: Sys.text|Sys.textDim; weight: 1.6 }`.
- Acento solo para lo activo/seleccionado y el transporte primario.
- Títulos de sección: `tSm` en `Sys.textDim`, MAYÚSCULAS discretas o sin ellas, sin adornos.
